// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";

import {PoppieFeeRouter} from "../../src/fee/PoppieFeeRouter.sol";
import {PoppieHubHook} from "../../src/hooks/PoppieHubHook.sol";
import {MAX_BORROW_PAUSE, MAX_LIQUIDATION_PAUSE} from "../../src/interfaces/IPoppieHubHook.sol";

import {HubHookFixture} from "../harness/HubHookFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Random driver for the fee flow. Well-formed batches, malformed batches (no forward, wrong receiver,
/// max amount, forward first, forward as another account), direct borrows, repays, fee changes, fee receiver
/// changes (including zero) and pauses. Reverting calls are expected and swallowed; the invariants then check what
/// must hold after any sequence.
contract FeeRouterHandler is Test {
    IEVC internal immutable evc;
    IEVault internal immutable hub;
    PoppieFeeRouter internal immutable router;
    PoppieHubHook internal immutable hook;
    MockERC20 internal immutable usdc;
    address internal immutable owner;
    address internal immutable ops;
    address internal immutable guard;
    address internal immutable governorAdmin;

    address[] internal receivers;

    uint256 public okBatches;
    uint256 public failedBatches;
    /// @dev Sum of fees expected by an independent ceil computation, per successful batch.
    uint256 public expectedFees;
    uint256 public expectedNet;
    uint256 public repaid;

    constructor(
        IEVC evc_,
        IEVault hub_,
        PoppieFeeRouter router_,
        PoppieHubHook hook_,
        MockERC20 usdc_,
        address owner_,
        address ops_,
        address guard_,
        address[] memory receivers_
    ) {
        evc = evc_;
        hub = hub_;
        router = router_;
        hook = hook_;
        usdc = usdc_;
        owner = owner_;
        ops = ops_;
        guard = guard_;
        governorAdmin = msg.sender;
        receivers = receivers_;
    }

    function _sub(uint8 i) internal view returns (address) {
        return address(uint160(owner) ^ uint160(i % 4));
    }

    function _item(address target, address account, bytes memory data) internal pure returns (IEVC.BatchItem memory) {
        return IEVC.BatchItem({targetContract: target, onBehalfOfAccount: account, value: 0, data: data});
    }

    function _send(IEVC.BatchItem[] memory items) internal returns (bool ok) {
        vm.prank(owner);
        try evc.batch(items) {
            ok = true;
            okBatches++;
        } catch {
            failedBatches++;
        }
    }

    /// @dev Well-formed borrow + forward.
    function borrowAndForward(uint256 amount, uint8 subIdx, uint8 toIdx) external {
        amount = bound(amount, 1, 50e6);
        address account = _sub(subIdx);
        address to = receivers[toIdx % receivers.length];
        address feeReceiver = hub.feeReceiver();
        uint256 bps = router.feeBps(address(hub));

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _item(address(hub), account, abi.encodeCall(IBorrowing.borrow, (amount, address(router))));
        items[1] = _item(address(router), account, abi.encodeCall(PoppieFeeRouter.forward, (address(hub), to)));
        if (_send(items) && feeReceiver != address(0)) {
            uint256 fee = (amount * bps + 9_999) / 10_000;
            expectedFees += fee;
            expectedNet += amount - fee;
        }
    }

    /// @dev Malformed variants; whether they revert or not, the invariants must hold.
    function malformed(uint256 amount, uint8 kind, uint8 subIdx) external {
        amount = bound(amount, 1, 50e6);
        address account = _sub(subIdx);
        address other = _sub(subIdx + 1);
        kind = kind % 5;

        IEVC.BatchItem[] memory items;
        if (kind == 0) {
            // No forward.
            items = new IEVC.BatchItem[](1);
            items[0] = _item(address(hub), account, abi.encodeCall(IBorrowing.borrow, (amount, address(router))));
        } else if (kind == 1) {
            // Forward as another account.
            items = new IEVC.BatchItem[](2);
            items[0] = _item(address(hub), account, abi.encodeCall(IBorrowing.borrow, (amount, address(router))));
            items[1] = _item(address(router), other, abi.encodeCall(PoppieFeeRouter.forward, (address(hub), other)));
        } else if (kind == 2) {
            // Max amount.
            items = new IEVC.BatchItem[](2);
            items[0] =
                _item(address(hub), account, abi.encodeCall(IBorrowing.borrow, (type(uint256).max, address(router))));
            items[1] = _item(address(router), account, abi.encodeCall(PoppieFeeRouter.forward, (address(hub), account)));
        } else if (kind == 3) {
            // Forward first.
            items = new IEVC.BatchItem[](2);
            items[0] = _item(address(router), account, abi.encodeCall(PoppieFeeRouter.forward, (address(hub), account)));
            items[1] = _item(address(hub), account, abi.encodeCall(IBorrowing.borrow, (amount, address(router))));
        } else {
            // Receiver is the account itself.
            items = new IEVC.BatchItem[](1);
            items[0] = _item(address(hub), account, abi.encodeCall(IBorrowing.borrow, (amount, account)));
        }
        _send(items);
    }

    /// @dev Direct (un-batched) borrow.
    function directBorrow(uint256 amount) external {
        amount = bound(amount, 1, 50e6);
        vm.prank(owner);
        try hub.borrow(amount, address(router)) {} catch {}
    }

    function repay(uint256 amount) external {
        amount = bound(amount, 1, 50e6);
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(hub), amount);
        try hub.repay(amount, owner) {
            repaid += amount;
        } catch {}
        vm.stopPrank();
    }

    function setFeeBps(uint16 bps) external {
        bps = uint16(bound(bps, 0, 100));
        vm.prank(ops);
        router.setFeeBps(address(hub), bps);
    }

    function setFeeReceiver(uint8 idx, bool zero) external {
        address r = zero ? address(0) : receivers[idx % receivers.length];
        vm.prank(governorAdmin);
        hub.setFeeReceiver(r);
    }

    function pauseBorrows(uint40 duration) external {
        duration = uint40(bound(duration, 1, MAX_BORROW_PAUSE));
        address[] memory hubs = new address[](1);
        hubs[0] = address(hub);
        vm.prank(guard);
        hook.pauseBorrows(hubs, duration);
    }

    function pauseLiquidations(uint40 duration) external {
        duration = uint40(bound(duration, 1, MAX_LIQUIDATION_PAUSE));
        address[] memory hubs = new address[](1);
        hubs[0] = address(hub);
        vm.prank(ops);
        hook.pauseLiquidations(hubs, duration);
    }

    function unpause() external {
        address[] memory hubs = new address[](1);
        hubs[0] = address(hub);
        vm.startPrank(ops);
        hook.unpauseBorrows(hubs);
        hook.unpauseLiquidations(hubs);
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }
}

contract FeeRouterInvariantsTest is HubHookFixture {
    FeeRouterHandler internal handler;
    address[] internal sinks;

    function setUp() public override {
        super.setUp();

        sinks.push(recipient);
        sinks.push(borrower);
        sinks.push(feeReceiver);
        sinks.push(makeAddr("sink3"));
        sinks.push(address(feeRouter)); // an invalid `to`: those batches must fail

        // Sub-accounts 1..3 of the borrower also need collateral and the hub as controller.
        for (uint8 i = 1; i < 4; ++i) {
            address sub = _sub(borrower, i);
            stock.mint(borrower, 10e18);
            vm.startPrank(borrower);
            stock.approve(address(escrow), 10e18);
            escrow.deposit(10e18, sub);
            evc.enableCollateral(sub, address(escrow));
            evc.enableController(sub, address(hub));
            vm.stopPrank();
        }

        handler = new FeeRouterHandler(evc, hub, feeRouter, hook, usdc, borrower, ops, guard, sinks);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = FeeRouterHandler.borrowAndForward.selector;
        selectors[1] = FeeRouterHandler.malformed.selector;
        selectors[2] = FeeRouterHandler.directBorrow.selector;
        selectors[3] = FeeRouterHandler.repay.selector;
        selectors[4] = FeeRouterHandler.setFeeBps.selector;
        selectors[5] = FeeRouterHandler.setFeeReceiver.selector;
        selectors[6] = FeeRouterHandler.pauseBorrows.selector;
        selectors[7] = FeeRouterHandler.pauseLiquidations.selector;
        selectors[8] = FeeRouterHandler.unpause.selector;
        selectors[9] = FeeRouterHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Guards against the handler silently never reaching the success path.
    function test_handlerReachesSuccessfulBatches() public {
        handler.borrowAndForward(10e6, 0, 0);
        handler.borrowAndForward(10e6, 1, 3);
        assertEq(handler.okBatches(), 2);
        assertGt(handler.expectedFees(), 0);
        handler.borrowAndForward(10e6, 2, 4); // `to` is the router
        assertEq(handler.failedBatches(), 1);
        handler.malformed(10e6, 0, 0);
        assertEq(handler.failedBatches(), 2);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    /// @dev No transaction changes the router's balance: after every call sequence it still holds nothing.
    function invariant_routerBalanceUnchanged() public view {
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    /// @dev Pending state never survives a transaction.
    function invariant_nothingPendingBetweenTransactions() public view {
        assertEq(feeRouter.pendingTotal(address(hub)), 0);
        for (uint8 i; i < 4; ++i) {
            assertEq(feeRouter.pending(address(hub), _sub(borrower, i)), 0);
        }
    }

    /// @dev Every unit the hub paid out through the router is accounted for: fees plus net equals the borrowed
    /// amounts of successful batches, and fee is exactly the ceiling of bps (checked by the handler).
    function invariant_feeAccountingMatchesIndependentComputation() public view {
        // Debt grew by the gross amount of every successful batch and shrank by repayments (and nothing else
        // changes a sub-account's debt here, interest is zero without an IRM).
        uint256 debt;
        for (uint8 i; i < 4; ++i) {
            debt += hub.debtOf(_sub(borrower, i));
        }
        assertEq(debt + handler.repaid(), handler.expectedFees() + handler.expectedNet());
    }
}
