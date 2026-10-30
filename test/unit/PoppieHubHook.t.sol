// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PoppieHubHook} from "../../src/hooks/PoppieHubHook.sol";
import {IPoppieHubHook, MAX_BORROW_PAUSE, MAX_LIQUIDATION_PAUSE} from "../../src/interfaces/IPoppieHubHook.sol";
import {HUB_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS, K_GUARD} from "../../src/access/Roles.sol";

import {HubHookFixture} from "../harness/HubHookFixture.sol";

/// @notice Registration, pauses and roles of `PoppieHubHook` (CONTRACT_SPEC.md section 3.4, V2_PLAN.md section 3).
contract PoppieHubHookTest is HubHookFixture {
    IEVault internal hub2;

    function setUp() public override {
        super.setUp();

        hub2 = _createHub();
        _configureHub(hub2);
        hub2.setLTV(address(escrow), 0.5e4, 0.6e4, 0);
        vm.prank(admin);
        hook.registerHub(address(hub2));
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub2), FEE_BPS);
    }

    function _hubs() internal view returns (address[] memory hubs) {
        hubs = new address[](2);
        hubs[0] = address(hub);
        hubs[1] = address(hub2);
    }

    function _one(address h) internal pure returns (address[] memory hubs) {
        hubs = new address[](1);
        hubs[0] = h;
    }

    function _expectUnauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    function _borrowReverts(bytes memory err) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hub, borrower, 10e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, recipient);
        vm.prank(borrower);
        vm.expectRevert(err);
        evc.batch(items);
    }

    /// @dev Make the borrower liquidatable and return a repay amount the liquidator can use.
    function _makeLiquidatable() internal returns (uint256 maxRepay) {
        _openDebt(borrower, 900e6);
        adapter.setPrice(address(stock), 100e18);
        (maxRepay,) = hub.checkLiquidation(liquidator, borrower, address(escrow));
        assertGt(maxRepay, 0);
    }

    // -- Hook config ----------------------------------------------------------------------------

    function test_isHookTarget() public view {
        assertEq(hook.isHookTarget(), IHookTarget.isHookTarget.selector);
        (address target, uint32 ops_) = hub.hookConfig();
        assertEq(target, address(hook));
        assertEq(ops_, HUB_HOOKED_OPS);
    }

    // -- registerHub ----------------------------------------------------------------------------

    function test_registerHub() public {
        IEVault h = _createHub();
        assertFalse(hook.isHub(address(h)));

        vm.expectEmit(true, false, false, false, address(hook));
        emit IPoppieHubHook.HubRegistered(address(h));
        vm.prank(admin);
        hook.registerHub(address(h));
        assertTrue(hook.isHub(address(h)));
    }

    function test_registerHubGuards() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieHubHook.ZeroAddress.selector);
        hook.registerHub(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.HubAlreadyRegistered.selector, address(hub)));
        hook.registerHub(address(hub));

        _expectUnauthorized(ops, hook.DEFAULT_ADMIN_ROLE());
        vm.prank(ops);
        hook.registerHub(makeAddr("x"));

        _expectUnauthorized(guard, hook.DEFAULT_ADMIN_ROLE());
        vm.prank(guard);
        hook.registerHub(makeAddr("x"));
    }

    function test_constructorsRejectZeroAddresses() public {
        vm.expectRevert(IPoppieHubHook.ZeroAddress.selector);
        new PoppieHubHook(address(0), address(evc), address(feeRouter));
        vm.expectRevert(IPoppieHubHook.ZeroAddress.selector);
        new PoppieHubHook(admin, address(0), address(feeRouter));
        vm.expectRevert(IPoppieHubHook.ZeroAddress.selector);
        new PoppieHubHook(admin, address(evc), address(0));
    }

    // -- Borrow pause ---------------------------------------------------------------------------

    function test_pauseBorrowsBlocksBorrowsUntilExpiry() public {
        uint40 until = uint40(block.timestamp) + 1 hours;

        vm.expectEmit(true, true, false, true, address(hook));
        emit IPoppieHubHook.BorrowsPaused(address(hub), until, guard);
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub)), 1 hours);
        assertEq(hook.borrowPausedUntil(address(hub)), until);

        _borrowReverts(abi.encodeWithSelector(IPoppieHubHook.BorrowsArePaused.selector, address(hub), until));

        // Last second of the pause: still paused.
        vm.warp(until - 1);
        _borrowReverts(abi.encodeWithSelector(IPoppieHubHook.BorrowsArePaused.selector, address(hub), until));

        // At `until` the pause has expired on its own.
        vm.warp(until);
        _borrowAndForward(borrower, 10e6, recipient);
        assertEq(hub.debtOf(borrower), 10e6);
    }

    function test_guardCanRepauseImmediatelyAfterExpiry() public {
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub)), MAX_BORROW_PAUSE);
        uint40 first = hook.borrowPausedUntil(address(hub));

        vm.warp(first);
        _borrowAndForward(borrower, 10e6, recipient); // expired: borrows work for this very second

        // No cooldown: K_GUARD pauses again in the same second the pause expired.
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub)), MAX_BORROW_PAUSE);
        assertEq(hook.borrowPausedUntil(address(hub)), first + MAX_BORROW_PAUSE);
        _borrowReverts(
            abi.encodeWithSelector(IPoppieHubHook.BorrowsArePaused.selector, address(hub), first + MAX_BORROW_PAUSE)
        );
    }

    function test_guardCanRepauseManyTimesBackToBack() public {
        for (uint256 i = 1; i <= 5; ++i) {
            vm.prank(guard);
            hook.pauseBorrows(_one(address(hub)), MAX_BORROW_PAUSE);
            assertEq(hook.borrowPausedUntil(address(hub)), block.timestamp + MAX_BORROW_PAUSE);
            vm.warp(hook.borrowPausedUntil(address(hub)));
        }
    }

    function test_pauseBorrowsDurationBounds() public {
        vm.startPrank(guard);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.InvalidPauseDuration.selector, 0, MAX_BORROW_PAUSE));
        hook.pauseBorrows(_one(address(hub)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IPoppieHubHook.InvalidPauseDuration.selector, MAX_BORROW_PAUSE + 1, MAX_BORROW_PAUSE)
        );
        hook.pauseBorrows(_one(address(hub)), MAX_BORROW_PAUSE + 1);

        hook.pauseBorrows(_one(address(hub)), MAX_BORROW_PAUSE);
        hook.pauseBorrows(_one(address(hub)), 1);
        vm.stopPrank();
        assertEq(MAX_BORROW_PAUSE, 24 hours);
    }

    function test_pauseBorrowsAppliesToEveryHubInArray() public {
        vm.prank(guard);
        hook.pauseBorrows(_hubs(), 2 hours);
        assertEq(hook.borrowPausedUntil(address(hub)), block.timestamp + 2 hours);
        assertEq(hook.borrowPausedUntil(address(hub2)), block.timestamp + 2 hours);
    }

    function test_pauseBorrowsRejectsUnregisteredHubAndRevertsWholeCall() public {
        address[] memory hubs = new address[](2);
        hubs[0] = address(hub);
        hubs[1] = makeAddr("notAHub");
        vm.prank(guard);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, hubs[1]));
        hook.pauseBorrows(hubs, 1 hours);
        assertEq(hook.borrowPausedUntil(address(hub)), 0);
    }

    function test_pauseBorrowsOnlyGuard() public {
        _expectUnauthorized(ops, K_GUARD);
        vm.prank(ops);
        hook.pauseBorrows(_one(address(hub)), 1 hours);

        address nobody = makeAddr("nobody");
        _expectUnauthorized(nobody, K_GUARD);
        vm.prank(nobody);
        hook.pauseBorrows(_one(address(hub)), 1 hours);
    }

    function test_borrowPauseIsPerHub() public {
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub2)), 1 hours);
        _borrowAndForward(borrower, 10e6, recipient); // hub is not paused
        assertEq(hub.debtOf(borrower), 10e6);
    }

    function test_borrowPauseDoesNotBlockRepayWithdrawDeposit() public {
        _openDebt(borrower, 100e6);
        vm.prank(guard);
        hook.pauseBorrows(_hubs(), 1 hours);

        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(hub), type(uint256).max);
        hub.repay(type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(hub.debtOf(borrower), 0);

        vm.startPrank(lender);
        hub.withdraw(1e6, lender, lender);
        usdc.approve(address(hub), type(uint256).max);
        hub.deposit(1e6, lender);
        vm.stopPrank();
    }

    function test_borrowPauseDoesNotBlockLiquidation() public {
        uint256 maxRepay = _makeLiquidatable();
        vm.prank(guard);
        hook.pauseBorrows(_hubs(), 1 hours);
        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
    }

    function test_unpauseBorrowsEndsPauseEarly() public {
        vm.prank(guard);
        hook.pauseBorrows(_hubs(), 24 hours);

        vm.expectEmit(true, true, false, false, address(hook));
        emit IPoppieHubHook.BorrowsUnpaused(address(hub), ops);
        vm.prank(ops);
        hook.unpauseBorrows(_one(address(hub)));
        assertEq(hook.borrowPausedUntil(address(hub)), 0);
        assertGt(hook.borrowPausedUntil(address(hub2)), block.timestamp, "other hub still paused");

        _borrowAndForward(borrower, 10e6, recipient);

        vm.prank(ops);
        hook.unpauseBorrows(_hubs());
        assertEq(hook.borrowPausedUntil(address(hub2)), 0);
    }

    function test_unpauseBorrowsIsNoOpWhenNotPaused() public {
        vm.recordLogs();
        vm.prank(ops);
        hook.unpauseBorrows(_hubs());
        assertEq(vm.getRecordedLogs().length, 0);

        // Expired pause: also a no-op.
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub)), 1 hours);
        vm.warp(block.timestamp + 1 hours);
        vm.recordLogs();
        vm.prank(ops);
        hook.unpauseBorrows(_one(address(hub)));
        assertEq(vm.getRecordedLogs().length, 0);

        // Not a hub at all: still a no-op.
        vm.prank(ops);
        hook.unpauseBorrows(_one(makeAddr("notAHub")));
    }

    function test_unpauseBorrowsOnlyMsOps() public {
        _expectUnauthorized(guard, MS_OPS);
        vm.prank(guard);
        hook.unpauseBorrows(_one(address(hub)));
    }

    function test_revokedGuardCannotPause() public {
        vm.prank(ops);
        hook.revokeRole(K_GUARD, guard);
        _expectUnauthorized(guard, K_GUARD);
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub)), 1 hours);
    }

    // -- Liquidation pause ----------------------------------------------------------------------

    function test_pauseLiquidationsBlocksLiquidationUntilExpiry() public {
        uint256 maxRepay = _makeLiquidatable();
        uint40 until = uint40(block.timestamp) + 6 hours;

        vm.expectEmit(true, true, false, true, address(hook));
        emit IPoppieHubHook.LiquidationsPaused(address(hub), until, ops);
        vm.prank(ops);
        hook.pauseLiquidations(_one(address(hub)), 6 hours);
        assertEq(hook.liquidationPausedUntil(address(hub)), until);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.LiquidationsArePaused.selector, address(hub), until));
        hub.liquidate(borrower, address(escrow), maxRepay, 0);

        vm.warp(until);
        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
    }

    function test_liquidationPausesCanBeChainedBackToBack() public {
        uint256 maxRepay = _makeLiquidatable();
        uint256 start = block.timestamp;

        // Ten consecutive 6h pauses (60h in total): each is set in the second the previous one expires.
        for (uint256 i = 1; i <= 10; ++i) {
            vm.prank(ops);
            hook.pauseLiquidations(_one(address(hub)), MAX_LIQUIDATION_PAUSE);
            assertEq(hook.liquidationPausedUntil(address(hub)), block.timestamp + MAX_LIQUIDATION_PAUSE);

            vm.prank(liquidator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPoppieHubHook.LiquidationsArePaused.selector, address(hub), block.timestamp + MAX_LIQUIDATION_PAUSE
                )
            );
            hub.liquidate(borrower, address(escrow), maxRepay, 0);

            vm.warp(hook.liquidationPausedUntil(address(hub)));
        }
        assertEq(block.timestamp, start + 60 hours);

        // Chaining can also happen before the previous pause expires (it replaces the expiry).
        vm.prank(ops);
        hook.pauseLiquidations(_one(address(hub)), 1 hours);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(ops);
        hook.pauseLiquidations(_one(address(hub)), MAX_LIQUIDATION_PAUSE);
        assertEq(hook.liquidationPausedUntil(address(hub)), block.timestamp + MAX_LIQUIDATION_PAUSE);

        // And liquidation resumes once the chain stops.
        vm.warp(hook.liquidationPausedUntil(address(hub)));
        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
    }

    function test_pauseLiquidationsDurationBounds() public {
        vm.startPrank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.InvalidPauseDuration.selector, 0, MAX_LIQUIDATION_PAUSE));
        hook.pauseLiquidations(_one(address(hub)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieHubHook.InvalidPauseDuration.selector, MAX_LIQUIDATION_PAUSE + 1, MAX_LIQUIDATION_PAUSE
            )
        );
        hook.pauseLiquidations(_one(address(hub)), MAX_LIQUIDATION_PAUSE + 1);

        // A borrow-length pause is too long for a liquidation pause.
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieHubHook.InvalidPauseDuration.selector, 24 hours, MAX_LIQUIDATION_PAUSE)
        );
        hook.pauseLiquidations(_one(address(hub)), 24 hours);

        hook.pauseLiquidations(_one(address(hub)), MAX_LIQUIDATION_PAUSE);
        vm.stopPrank();
        assertEq(MAX_LIQUIDATION_PAUSE, 6 hours);
    }

    function test_pauseLiquidationsAppliesToEveryHubInArray() public {
        vm.prank(ops);
        hook.pauseLiquidations(_hubs(), 3 hours);
        assertEq(hook.liquidationPausedUntil(address(hub)), block.timestamp + 3 hours);
        assertEq(hook.liquidationPausedUntil(address(hub2)), block.timestamp + 3 hours);
    }

    function test_pauseLiquidationsRejectsUnregisteredHub() public {
        address[] memory hubs = new address[](2);
        hubs[0] = address(hub);
        hubs[1] = makeAddr("notAHub");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, hubs[1]));
        hook.pauseLiquidations(hubs, 1 hours);
        assertEq(hook.liquidationPausedUntil(address(hub)), 0);
    }

    function test_pauseLiquidationsOnlyMsOps() public {
        _expectUnauthorized(guard, MS_OPS);
        vm.prank(guard);
        hook.pauseLiquidations(_one(address(hub)), 1 hours);
    }

    function test_liquidationPauseDoesNotBlockBorrowRepayDeposit() public {
        vm.prank(ops);
        hook.pauseLiquidations(_hubs(), 6 hours);

        _openDebt(borrower, 100e6);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(hub), type(uint256).max);
        hub.repay(type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(hub.debtOf(borrower), 0);

        usdc.mint(lender, 1e6);
        vm.prank(lender);
        hub.deposit(1e6, lender);
    }

    function test_unpauseLiquidationsEndsPauseEarly() public {
        uint256 maxRepay = _makeLiquidatable();
        vm.prank(ops);
        hook.pauseLiquidations(_hubs(), 6 hours);

        vm.expectEmit(true, true, false, false, address(hook));
        emit IPoppieHubHook.LiquidationsUnpaused(address(hub), ops);
        vm.prank(ops);
        hook.unpauseLiquidations(_one(address(hub)));
        assertEq(hook.liquidationPausedUntil(address(hub)), 0);
        assertGt(hook.liquidationPausedUntil(address(hub2)), block.timestamp);

        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
    }

    function test_unpauseLiquidationsIsNoOpWhenNotPaused() public {
        vm.recordLogs();
        vm.prank(ops);
        hook.unpauseLiquidations(_hubs());
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_unpauseLiquidationsOnlyMsOps() public {
        _expectUnauthorized(guard, MS_OPS);
        vm.prank(guard);
        hook.unpauseLiquidations(_one(address(hub)));
    }

    function test_msOpsEndsBothPausesEarly() public {
        vm.prank(guard);
        hook.pauseBorrows(_hubs(), 24 hours);
        vm.prank(ops);
        hook.pauseLiquidations(_hubs(), 6 hours);

        vm.startPrank(ops);
        hook.unpauseBorrows(_hubs());
        hook.unpauseLiquidations(_hubs());
        vm.stopPrank();

        assertEq(hook.borrowPausedUntil(address(hub)), 0);
        assertEq(hook.borrowPausedUntil(address(hub2)), 0);
        assertEq(hook.liquidationPausedUntil(address(hub)), 0);
        assertEq(hook.liquidationPausedUntil(address(hub2)), 0);
    }

    // -- Fuzz -----------------------------------------------------------------------------------

    function testFuzz_borrowPauseWindow(uint40 duration, uint40 elapsed) public {
        duration = uint40(bound(duration, 1, MAX_BORROW_PAUSE));
        elapsed = uint40(bound(elapsed, 0, 2 * MAX_BORROW_PAUSE));
        vm.prank(guard);
        hook.pauseBorrows(_one(address(hub)), duration);
        vm.warp(block.timestamp + elapsed);

        if (elapsed < duration) {
            _borrowReverts(
                abi.encodeWithSelector(
                    IPoppieHubHook.BorrowsArePaused.selector, address(hub), hook.borrowPausedUntil(address(hub))
                )
            );
        } else {
            _borrowAndForward(borrower, 1e6, recipient);
            // Immediately re-pausable.
            vm.prank(guard);
            hook.pauseBorrows(_one(address(hub)), duration);
        }
    }
}
