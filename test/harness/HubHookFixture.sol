// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {PoppieFeeRouter} from "../../src/fee/PoppieFeeRouter.sol";
import {PoppieHubHook} from "../../src/hooks/PoppieHubHook.sol";
import {HUB_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS, K_GUARD} from "../../src/access/Roles.sol";

import {PoppieTestBase} from "./PoppieTestBase.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";

/// @notice Local EVK stack with the real `PoppieHubHook` and `PoppieFeeRouter` installed on a hub: one registered
/// hub, a lender with USDC in it, a borrower with stock collateral in an escrow vault, a liquidator, and helpers
/// that build the EVC batches an integrator sends. No fork.
abstract contract HubHookFixture is PoppieTestBase {
    PoppieHubHook internal hook;
    PoppieFeeRouter internal feeRouter;
    MockPriceAdapter internal adapter;
    IEVault internal hub;
    IEVault internal escrow;

    address internal ops = makeAddr("ops");
    address internal guard = makeAddr("guard");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant STOCK_PRICE = 200e18;
    uint256 internal constant USDC_PRICE = 1e18;
    uint16 internal constant FEE_BPS = 25;

    function setUp() public virtual override {
        super.setUp();

        adapter = new MockPriceAdapter();
        adapter.setPrice(address(stock), STOCK_PRICE);
        adapter.setPrice(address(usdc), USDC_PRICE);

        // Hook <-> router wiring: both immutable, so the hook (deployed first) gets the router's CREATE address.
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        hook = new PoppieHubHook(admin, address(evc), predictedRouter);
        feeRouter = new PoppieFeeRouter(admin, address(evc), address(hook));
        assertEq(address(feeRouter), predictedRouter);

        vm.startPrank(admin);
        hook.grantRole(MS_OPS, ops);
        hook.grantRole(K_GUARD, guard);
        feeRouter.grantRole(MS_OPS, ops);
        vm.stopPrank();

        hub = _createHub();
        escrow = _createEscrow(address(stock));

        router.govSetConfig(address(stock), USD, address(adapter));
        router.govSetConfig(address(usdc), USD, address(adapter));
        router.govSetResolvedVault(address(escrow), true);

        _configureHub(hub);
        hub.setLTV(address(escrow), 0.5e4, 0.6e4, 0);

        vm.prank(admin);
        hook.registerHub(address(hub));
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub), FEE_BPS);

        // Lender supplies USDC.
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(hub), type(uint256).max);
        hub.deposit(1_000_000e6, lender);
        vm.stopPrank();

        // Borrower: 10 stock (2,000 USD) as collateral, hub enabled as controller.
        _depositCollateral(borrower, 10e18);
        vm.startPrank(borrower);
        evc.enableCollateral(borrower, address(escrow));
        evc.enableController(borrower, address(hub));
        vm.stopPrank();

        // Liquidator has deep collateral of its own so seizing a position keeps it healthy.
        _depositCollateral(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        evc.enableCollateral(liquidator, address(escrow));
        evc.enableController(liquidator, address(hub));
        usdc.approve(address(hub), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Hub settings of a Poppie hub that matter here: hook config and fee receiver.
    function _configureHub(IEVault h) internal {
        h.setMaxLiquidationDiscount(0.1e4);
        h.setCaps(0, 0);
        h.setFeeReceiver(feeReceiver);
        h.setHookConfig(address(hook), HUB_HOOKED_OPS);
    }

    function _depositCollateral(address who, uint256 amount) internal {
        stock.mint(who, amount);
        vm.startPrank(who);
        stock.approve(address(escrow), amount);
        escrow.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Sub-account `i` of `owner` (same owner, so one `msg.sender` can act for both).
    function _sub(address owner, uint8 i) internal pure returns (address) {
        return address(uint160(owner) ^ uint160(i));
    }

    // -- Batch builders -------------------------------------------------------------------------

    function _borrowItem(IEVault h, address account, uint256 amount, address receiver)
        internal
        pure
        returns (IEVC.BatchItem memory)
    {
        return IEVC.BatchItem({
            targetContract: address(h),
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(IBorrowing.borrow, (amount, receiver))
        });
    }

    function _forwardItem(address h, address account, address to) internal view returns (IEVC.BatchItem memory) {
        return IEVC.BatchItem({
            targetContract: address(feeRouter),
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(PoppieFeeRouter.forward, (h, to))
        });
    }

    function _batch(address sender, IEVC.BatchItem[] memory items) internal {
        vm.prank(sender);
        evc.batch(items);
    }

    /// @dev The batch an integrator sends: borrow to the router, then forward to `to`.
    function _borrowAndForward(address account, uint256 amount, address to) internal {
        _borrowAndForward(hub, account, amount, to);
    }

    function _borrowAndForward(IEVault h, address account, uint256 amount, address to) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(h, account, amount, address(feeRouter));
        items[1] = _forwardItem(address(h), account, to);
        _batch(account, items);
    }

    /// @dev Open a position: borrow `amount` through the router; the net lands with `account`.
    function _openDebt(address account, uint256 amount) internal {
        _borrowAndForward(account, amount, account);
    }
}
