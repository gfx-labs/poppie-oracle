// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P1Base} from "../lib/P1Base.sol";
import {MockVault} from "../lib/Mocks.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";
import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

contract HubGuardUnitTest is P1Base {
    function test_isHookTarget() public view {
        assertEq(g.isHookTarget(), HubGuard.isHookTarget.selector);
    }

    function test_borrowWithFee_passes_andClearsBatch() public {
        _batch(user, 100e6, _fee(100e6));
        (bool borrowed, uint256 before, uint256 owed, uint256 paid) = g.batch(address(hub));
        assertFalse(borrowed);
        assertEq(before + owed + paid, 0);
        (,,,,,,,, uint256 used) = g.cfg(address(hub));
        assertEq(used, 100e6 + _fee(100e6));
    }

    // ── fees ──
    function test_feeShort_reverts() public {
        _batchReverts(user, _borrowCalls(user, 100e6, _fee(100e6) - 1), abi.encodePacked(HubGuard.FeeShort.selector));
    }

    function test_directBorrow_withFeeSet_reverts() public {
        _batchReverts(user, _borrowCalls(user, 100e6, 0), abi.encodePacked(HubGuard.FeeShort.selector));
    }

    function test_feeRoundsUp() public {
        assertEq(_fee(1), 1);
        assertEq(_fee(199), 1);
        assertEq(_fee(200), 1);
        assertEq(_fee(201), 2);
        _batch(user, 1, 1);
        _batch(user, 200, 1);
        _batchReverts(user, _borrowCalls(user, 201, 1), abi.encodePacked(HubGuard.FeeShort.selector));
        _batch(user, 201, 2);
    }

    function test_feeByOtherAccount_counts() public {
        vm.prank(user);
        hub.borrow(100e6, user);
        vm.prank(makeAddr("payer"));
        hub.borrow(_fee(100e6), feeRcv);
        hub.statusCheck();
    }

    function test_feeZero_noRequirement() public {
        vm.prank(ops);
        g.setHub(address(hub), LIMIT, WINDOW, 0, address(0), 1);
        _batch(user, 100e6, 0);
    }

    function test_setHub_feeAboveMax_reverts() public {
        vm.prank(ops);
        vm.expectRevert(HubGuard.InvalidConfig.selector);
        g.setHub(address(hub), LIMIT, WINDOW, 101, feeRcv, 1);
        vm.prank(ops);
        vm.expectRevert(HubGuard.InvalidConfig.selector);
        g.setHub(address(hub), LIMIT, WINDOW, 10, address(0), 1);
        vm.prank(ops);
        vm.expectRevert(HubGuard.InvalidConfig.selector);
        g.setHub(address(hub), LIMIT, WINDOW, 10, feeRcv, 2);
    }

    function test_onlyOwnerSetsHub() public {
        vm.expectRevert(HubGuard.Unauthorized.selector);
        g.setHub(address(hub), LIMIT, WINDOW, 0, address(0), 1);
    }

    // ── all-cash / flash ──
    function test_allCash_reverts() public {
        vm.prank(user);
        vm.expectRevert(HubGuard.AllCash.selector);
        hub.borrow(type(uint256).max, user);
    }

    function test_flash_on_off() public {
        hub.flashLoan(1e6, "");
        vm.prank(ops);
        g.setHub(address(hub), LIMIT, WINDOW, FEE, feeRcv, 0);
        vm.expectRevert(HubGuard.FlashDisabled.selector);
        hub.flashLoan(1e6, "");
    }

    // ── rate limit ──
    function test_limit_singleBatch() public {
        uint256 x = 995e6; // + fee 4.975e6 = 999.975e6
        _batch(user, x, _fee(x));
        _batch(user, 20e3, _fee(20e3)); // 999.995100e6 total
        _batchReverts(user, _borrowCalls(user, 5e3, _fee(5e3)), abi.encodePacked(HubGuard.LimitExceeded.selector));
        _batch(user, 4e3, _fee(4e3)); // exactly at the limit is fine
        (,,,,,,,, uint256 used) = g.cfg(address(hub));
        assertEq(used, LIMIT - 880);
    }

    function test_limit_overInOneBatch_reverts() public {
        _batchReverts(user, _borrowCalls(user, LIMIT, _fee(LIMIT)), abi.encodePacked(HubGuard.LimitExceeded.selector));
    }

    function test_limit_windowRoll() public {
        _batch(user, 900e6, _fee(900e6));
        vm.warp(block.timestamp + WINDOW - 1);
        _batchReverts(user, _borrowCalls(user, 100e6, _fee(100e6)), abi.encodePacked(HubGuard.LimitExceeded.selector));
        vm.warp(block.timestamp + 1);
        _batch(user, 900e6, _fee(900e6));
        (,,,,, uint40 ws,,,) = g.cfg(address(hub));
        assertEq(ws, block.timestamp);
    }

    function test_limit_isNet_repayInSameBatch() public {
        vm.prank(ops);
        g.setHub(address(hub), LIMIT, WINDOW, 0, address(0), 1);
        vm.prank(user);
        hub.batch(_calls(_b(1_500e6, user), abi.encodeCall(MockVault.repay, (600e6, user)))); // net 900 <= 1000
        _batchReverts(user, _calls(_b(200e6, user)), abi.encodePacked(HubGuard.LimitExceeded.selector));
    }

    function test_limit_ignoresInterestAndLiquidation() public {
        vm.prank(ops);
        g.setHub(address(hub), LIMIT, WINDOW, 0, address(0), 1);
        hub.setTotalBorrows(5_000e6); // pre-existing debt incl. accrued interest
        _batch(user, 1_000e6, 0);
        hub.setDebt(user, 1_000e6);
        vm.prank(makeAddr("liq"));
        hub.liquidate(user, address(0), 500e6, 0);
        hub.statusCheck();
    }

    function test_beforeCapturedOncePerBatch() public {
        vm.startPrank(user);
        hub.borrow(100e6, user);
        (, uint256 b1,,) = g.batch(address(hub));
        hub.borrow(_fee(100e6), feeRcv);
        (, uint256 b2,,) = g.batch(address(hub));
        vm.stopPrank();
        assertEq(b1, 0);
        assertEq(b2, 0);
        hub.statusCheck();
    }

    function test_twoBatchesOneTx_isolated() public {
        _batch(user, 400e6, _fee(400e6));
        (, uint256 before,,) = g.batch(address(hub));
        assertEq(before, 0);
        _batch(user, 400e6, _fee(400e6));
        (,,,,,,,, uint256 used) = g.cfg(address(hub));
        assertEq(used, 800e6 + 2 * _fee(400e6));
    }

    // ── status check wiring ──
    function test_statusCheckNotHooked_reverts() public {
        hub.setHookConfig(address(g), HUB_OPS & ~EVKOps.OP_VAULT_STATUS_CHECK);
        vm.prank(user);
        vm.expectRevert(HubGuard.StatusCheckNotHooked.selector);
        hub.borrow(1e6, user);
    }

    function test_statusCheck_noBorrow_passes_evenUnconfigured() public {
        MockVault other = new MockVault(address(0));
        other.setHookConfig(address(g), ALL_OPS);
        other.statusCheck();
        hub.statusCheck();
    }

    // ── unconfigured hub (A20) ──
    function test_unconfiguredHub_reverts() public {
        MockVault other = new MockVault(address(0));
        other.setHookConfig(address(g), HUB_OPS);
        vm.startPrank(user);
        vm.expectRevert(HubGuard.NotHub.selector);
        other.borrow(1, user);
        vm.expectRevert(HubGuard.NotHub.selector);
        other.deposit(1, user);
        vm.expectRevert(HubGuard.NotHub.selector);
        other.flashLoan(1, "");
        vm.stopPrank();
    }

    function test_directCallWithoutCaller_reverts() public {
        vm.prank(address(hub));
        vm.expectRevert(HubGuard.NotHub.selector);
        (bool ok,) = address(g).call(abi.encodeWithSignature("deposit(uint256,address)", 1, user));
        ok;
    }

    // ── pause ──
    function test_pause_blocksBorrowAndFlash_notDeposit() public {
        vm.prank(guardian);
        g.pause(address(hub), 1 hours);
        vm.startPrank(user);
        vm.expectRevert(HubGuard.Paused.selector);
        hub.borrow(1e6, user);
        vm.expectRevert(HubGuard.Paused.selector);
        hub.flashLoan(1, "");
        hub.deposit(1e6, user);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        _batch(user, 1e6, _fee(1e6));
    }

    function test_pause_raiseOnly_bounded() public {
        vm.startPrank(guardian);
        g.pause(address(hub), 2 hours);
        g.pause(address(hub), 1 hours);
        (,,,, uint40 until,,,,) = g.cfg(address(hub));
        assertEq(until, block.timestamp + 2 hours);
        vm.expectRevert(HubGuard.InvalidConfig.selector);
        g.pause(address(hub), 7 days + 1);
        vm.stopPrank();
        vm.expectRevert(HubGuard.Unauthorized.selector);
        g.pause(address(hub), 1);
    }

    function test_unpause_byOwner() public {
        vm.prank(guardian);
        g.pause(address(hub), 1 hours);
        vm.prank(guardian);
        vm.expectRevert(HubGuard.Unauthorized.selector);
        g.unpause(address(hub));
        vm.prank(ops);
        g.unpause(address(hub));
        _batch(user, 1e6, _fee(1e6));
    }

    // ── screening ──
    function test_denied_owner_blocked() public {
        vm.prank(denylister);
        g.deny(_arr(user));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, user));
        hub.borrow(1e6, user);
    }

    function test_sanctioned_receiver_blocked() public {
        address bad = makeAddr("bad");
        sanc.set(bad, true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, bad));
        hub.borrow(1e6, bad);
    }

    function test_subAccount_screensEvcOwner() public {
        address sub = address(uint160(user) ^ 1);
        evc.setOwner(sub, user);
        sanc.set(user, true);
        vm.prank(sub);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, user));
        hub.borrow(1e6, sub == user ? user : makeAddr("rcv"));
    }

    function test_unregisteredOwner_screensAccount() public {
        sanc.set(user, true); // evc owner is 0 for user
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, user));
        hub.borrow(1e6, makeAddr("rcv"));
    }

    function test_depositMintSkim_screened() public {
        address bad = makeAddr("bad");
        sanc.set(bad, true);
        bytes memory err = abi.encodeWithSelector(HubGuard.Blocked.selector, bad);
        vm.startPrank(user);
        vm.expectRevert(err);
        hub.deposit(1, bad);
        vm.expectRevert(err);
        hub.mint(1, bad);
        vm.expectRevert(err);
        hub.skim(1, bad);
        vm.stopPrank();
        vm.startPrank(bad);
        vm.expectRevert(err);
        hub.deposit(1, user);
        vm.stopPrank();
    }

    function test_deny_addOnly_ownerRemoves() public {
        vm.prank(denylister);
        g.deny(_arr(user));
        assertTrue(g.isBlocked(user));
        vm.prank(denylister);
        vm.expectRevert(HubGuard.Unauthorized.selector);
        g.removeDenied(user);
        vm.prank(ops);
        g.removeDenied(user);
        assertFalse(g.isBlocked(user));
    }

    // ── Rule 1: repay / liquidate / withdraw never blocked ──
    function test_worstCase_allBitsHooked_everyBlockActive() public {
        // debt exists, then everything is switched on
        _batch(user, 900e6, _fee(900e6));
        hub.setHookConfig(address(g), ALL_OPS);
        vm.prank(guardian);
        g.pause(address(hub), 7 days);
        vm.prank(denylister);
        g.deny(_arr(user));
        sanc.set(user, true);
        hub.deposit(0, address(this)); // shares for withdraw below (this is not blocked)

        vm.prank(user);
        hub.repay(100e6, user);
        hub.statusCheck();
        vm.prank(makeAddr("liq"));
        hub.liquidate(user, address(0), 100e6, 0);
        hub.statusCheck();
        hub.withdraw(0, address(this), address(this));
        hub.redeem(0, address(this), address(this));
        hub.touch();
        hub.statusCheck();
    }

    function test_hookRemoved_plainBehaviour() public {
        vm.prank(guardian);
        g.pause(address(hub), 1 days);
        hub.setHookConfig(address(0), 0);
        _batch(user, 5_000e6, 0); // over limit, no fee, paused: guard not involved
    }

    function test_bitsWithZeroTarget_disableOp() public {
        hub.setHookConfig(address(0), EVKOps.OP_BORROW);
        vm.expectRevert(MockVault.OperationDisabled.selector);
        hub.borrow(1, user);
    }

    function test_roles() public {
        vm.startPrank(ops);
        g.setGuardian(address(1));
        g.setDenylister(address(2));
        g.setOwner(address(3));
        vm.stopPrank();
        assertEq(g.guardian(), address(1));
        assertEq(g.denylister(), address(2));
        assertEq(g.owner(), address(3));
        vm.prank(ops);
        vm.expectRevert(HubGuard.Unauthorized.selector);
        g.setGuardian(ops);
    }
}
