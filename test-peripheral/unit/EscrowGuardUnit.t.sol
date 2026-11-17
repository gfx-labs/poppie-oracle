// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P2Base} from "../lib/P2Base.sol";
import {MockVault} from "../lib/Mocks.sol";
import {EscrowGuard} from "../../src/peripheral/EscrowGuard.sol";
import {IEVCSubset as IEVC} from "../../src/peripheral/interfaces/IEVCSubset.sol";
import {ISanctionsList as ISanc} from "../../src/peripheral/interfaces/ISanctionsList.sol";

contract EscrowGuardUnitTest is P2Base {
    function test_isHookTarget() public view {
        assertEq(g.isHookTarget(), EscrowGuard.isHookTarget.selector);
    }

    // ── windows: boundaries ──
    function test_window_startInclusive_endExclusive() public {
        uint256 s = DAY0 + 12 hours;
        _addWindow(G, s, s + 1 hours);
        vm.warp(s - 1);
        vm.prank(user);
        e1.deposit(1, user);
        vm.warp(s);
        vm.startPrank(user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.deposit(1, user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.withdraw(1, user, user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.redeem(1, user, user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.mint(1, user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.skim(1, user);
        vm.stopPrank();
        vm.warp(s + 1 hours - 1);
        vm.prank(user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.withdraw(1, user, user);
        vm.warp(s + 1 hours);
        vm.startPrank(user);
        e1.deposit(1, user);
        e1.withdraw(1, user, user);
        vm.stopPrank();
    }

    function test_window_appliesToWholeGroupOnly() public {
        uint256 s = DAY0 + 12 hours;
        _addWindow(G, s, s + 1 hours);
        vm.warp(s);
        vm.startPrank(user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e2.deposit(1, user); // same group
        e3.deposit(1, user); // other group unaffected
        e3.withdraw(1, user, user);
        vm.stopPrank();
    }

    // ── window bounds ──
    function test_addWindow_bounds() public {
        uint256 s = DAY0 + 12 hours;
        vm.startPrank(scheduler);
        vm.expectRevert(EscrowGuard.InvalidWindow.selector);
        g.addWindow(G, uint40(block.timestamp - 1), uint40(block.timestamp + 1)); // in the past
        vm.expectRevert(EscrowGuard.InvalidWindow.selector);
        g.addWindow(G, uint40(s), uint40(s)); // empty
        vm.expectRevert(EscrowGuard.InvalidWindow.selector);
        g.addWindow(G, uint40(s), uint40(s + MAX_LEN + 1)); // too long
        g.addWindow(G, uint40(s), uint40(s + MAX_LEN)); // exactly max
        vm.expectRevert(EscrowGuard.InvalidWindow.selector);
        g.addWindow(address(0), uint40(s), uint40(s + 1));
        vm.stopPrank();
    }

    function test_addWindow_startNowAllowed() public {
        _addWindow(G, block.timestamp, block.timestamp + 1);
        assertTrue(g.inWindow(G));
    }

    function test_addWindow_midnight() public {
        uint256 midnight = DAY0 + 1 days;
        vm.startPrank(scheduler);
        vm.expectRevert(EscrowGuard.InvalidWindow.selector);
        g.addWindow(G, uint40(midnight - 1 hours), uint40(midnight + 1)); // crosses
        g.addWindow(G, uint40(midnight - 1 hours), uint40(midnight)); // ends exactly at midnight
        g.addWindow(G, uint40(midnight), uint40(midnight + 1 hours)); // starts at midnight: next day
        vm.stopPrank();
        assertEq(g.windowsOf(G, DAY0 / 1 days).length, 1);
        assertEq(g.windowsOf(G, DAY0 / 1 days + 1).length, 1);
        vm.warp(midnight - 1);
        assertTrue(g.inWindow(G));
        vm.warp(midnight);
        assertTrue(g.inWindow(G));
        vm.warp(midnight + 1 hours);
        assertFalse(g.inWindow(G));
    }

    function test_addWindow_perDayLimit_perGroup() public {
        uint256 s = DAY0 + 12 hours;
        for (uint256 i; i < MAX_PER_DAY; ++i) _addWindow(G, s + i * 1 hours, s + i * 1 hours + 10 minutes);
        vm.prank(scheduler);
        vm.expectRevert(EscrowGuard.TooManyWindows.selector);
        g.addWindow(G, uint40(s + 5 hours), uint40(s + 6 hours));
        _addWindow(H, s, s + 1 hours); // other group has its own budget
        _addWindow(G, s + 1 days, s + 1 days + 1 hours); // next day has its own budget
    }

    function test_addWindow_onlyScheduler() public {
        vm.expectRevert(EscrowGuard.Unauthorized.selector);
        g.addWindow(G, uint40(block.timestamp + 1), uint40(block.timestamp + 2));
    }

    function test_clearWindows_ownerOnly() public {
        uint256 s = DAY0 + 12 hours;
        _addWindow(G, s, s + 1 hours);
        vm.prank(scheduler);
        vm.expectRevert(EscrowGuard.Unauthorized.selector);
        g.clearWindows(G, DAY0 / 1 days);
        vm.prank(ops);
        g.clearWindows(G, DAY0 / 1 days);
        vm.warp(s);
        assertFalse(g.inWindow(G));
    }

    // ── guardian deposit pause ──
    function test_pause_blocksInflowsOnly() public {
        vm.prank(guardian);
        g.pauseDeposits(address(e1), 1 hours);
        vm.startPrank(user);
        vm.expectRevert(EscrowGuard.Paused.selector);
        e1.deposit(1, user);
        vm.expectRevert(EscrowGuard.Paused.selector);
        e1.mint(1, user);
        vm.expectRevert(EscrowGuard.Paused.selector);
        e1.skim(1, user);
        e1.withdraw(1, user, user);
        e2.deposit(1, user); // per escrow
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(user);
        e1.deposit(1, user);
    }

    function test_pause_raiseOnly_bounded_ownerUnpauses() public {
        vm.startPrank(guardian);
        g.pauseDeposits(address(e1), 2 hours);
        g.pauseDeposits(address(e1), 1 hours);
        assertEq(g.pausedUntil(address(e1)), block.timestamp + 2 hours);
        vm.expectRevert(EscrowGuard.InvalidConfig.selector);
        g.pauseDeposits(address(e1), 7 days + 1);
        vm.expectRevert(EscrowGuard.Unauthorized.selector);
        g.unpause(address(e1));
        vm.stopPrank();
        vm.prank(ops);
        g.unpause(address(e1));
        assertEq(g.pausedUntil(address(e1)), 0);
    }

    // ── screening ──
    function test_screening_ownerAndReceiver() public {
        address bad = makeAddr("bad");
        sanc.set(bad, true);
        bytes memory err = abi.encodeWithSelector(EscrowGuard.Blocked.selector, bad);
        vm.prank(user);
        vm.expectRevert(err);
        e1.deposit(1, bad);
        vm.prank(bad);
        vm.expectRevert(err);
        e1.mint(1, user);
        address sub = address(uint160(bad) ^ 7);
        evc.setOwner(sub, bad);
        vm.prank(sub);
        vm.expectRevert(err);
        e1.skim(1, sub);
    }

    function test_deny_addOnly() public {
        vm.prank(denylister);
        g.deny(_arr(user));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EscrowGuard.Blocked.selector, user));
        e1.deposit(1, user);
        vm.prank(user);
        e1.withdraw(1, user, user); // exits are not screened
        vm.prank(denylister);
        vm.expectRevert(EscrowGuard.Unauthorized.selector);
        g.removeDenied(user);
        vm.prank(ops);
        g.removeDenied(user);
        assertFalse(g.isBlocked(user));
    }

    // ── groups / unconfigured (A20, A23) ──
    function test_unconfigured_inflowReverts_outflowPasses() public {
        MockVault e4 = new MockVault(address(0));
        e4.setHookConfig(address(g), ESCROW_OPS);
        vm.startPrank(user);
        vm.expectRevert(EscrowGuard.NotEscrow.selector);
        e4.deposit(1, user);
        vm.stopPrank();
        vm.prank(ops);
        g.setEscrow(address(e1), address(0)); // unconfigure
        _addWindow(G, block.timestamp, block.timestamp + 1 hours);
        vm.startPrank(user);
        e1.withdraw(1, user, user);
        vm.expectRevert(EscrowGuard.NotEscrow.selector);
        e1.deposit(1, user);
        vm.stopPrank();
    }

    function test_regroup_movesWindows() public {
        _addWindow(H, block.timestamp, block.timestamp + 1 hours);
        vm.prank(user);
        e1.deposit(1, user);
        vm.prank(ops);
        g.setEscrow(address(e1), H);
        vm.prank(user);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.deposit(1, user);
    }

    function test_constructorBounds() public {
        vm.expectRevert(EscrowGuard.InvalidConfig.selector);
        new EscrowGuard(evc_(), sanc_(), 1 days + 1, 3, 1, ops, guardian, scheduler, denylister);
        vm.expectRevert(EscrowGuard.InvalidConfig.selector);
        new EscrowGuard(evc_(), sanc_(), 1 hours, 0, 1, ops, guardian, scheduler, denylister);
    }

    function test_roles() public {
        vm.startPrank(ops);
        g.setGuardian(address(1));
        g.setScheduler(address(2));
        g.setDenylister(address(3));
        g.setOwner(address(4));
        vm.stopPrank();
        assertEq(g.guardian(), address(1));
        assertEq(g.scheduler(), address(2));
        assertEq(g.denylister(), address(3));
        assertEq(g.owner(), address(4));
    }

    function test_hookRemoved_plainBehaviour() public {
        _addWindow(G, block.timestamp, block.timestamp + 1 hours);
        e1.setHookConfig(address(0), 0);
        vm.startPrank(user);
        e1.deposit(1, user);
        e1.withdraw(1, user, user);
        vm.stopPrank();
    }

    function evc_() internal view returns (IEVC) {
        return IEVC(address(evc));
    }

    function sanc_() internal view returns (ISanc) {
        return ISanc(address(sanc));
    }
}
