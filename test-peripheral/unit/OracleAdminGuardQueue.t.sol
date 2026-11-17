// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P3Base} from "../lib/P3Base.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {OracleAdminGuard} from "../../src/peripheral/OracleAdminGuard.sol";

contract OracleAdminGuardQueueTest is P3Base {
    bytes internal far; // out-of-band price for A

    function setUp() public override {
        super.setUp();
        far = _setPrice(A, 200e18);
        _submit(far);
    }

    function test_executeTooEarly_reverts() public {
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.TooEarly.selector, _id(far)));
        g.execute(address(oracle), far);
    }

    function test_executeAtEta_lands_andClears() public {
        vm.warp(block.timestamp + DELAY);
        _exec(far);
        assertEq(_cfg(A).lastPrice, 200e18);
        assertEq(g.eta(_id(far)), 0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.NotQueued.selector, _id(far)));
        g.execute(address(oracle), far);
    }

    function test_onlySafeExecutes() public {
        vm.warp(block.timestamp + DELAY);
        vm.prank(guardian);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.execute(address(oracle), far);
    }

    function test_expiry_atEtaPlusDelay() public {
        uint256 e = g.eta(_id(far));
        vm.warp(e + DELAY); // last valid second
        _exec(far);
        assertEq(_cfg(A).lastPrice, 200e18);
    }

    function test_expired_reverts_thenRequeueAllowed() public {
        uint256 e = g.eta(_id(far));
        vm.warp(e + DELAY + 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.Expired.selector, _id(far)));
        g.execute(address(oracle), far);
        _submit(far); // re-queue after expiry
        assertEq(g.eta(_id(far)), block.timestamp + DELAY);
    }

    function test_requeuePending_reverts() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.AlreadyQueued.selector, _id(far)));
        g.submit(address(oracle), far);
    }

    function test_approve_secondSafe_landsNow() public {
        vm.prank(second);
        g.approveQueued(address(oracle), far);
        assertEq(_cfg(A).lastPrice, 200e18);
        assertEq(g.eta(_id(far)), 0);
    }

    function test_approve_onlySecondSafe() public {
        vm.prank(safe);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.approveQueued(address(oracle), far);
    }

    function test_approve_limitedToAdminSetPrice() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (0));
        _submit(d);
        vm.prank(second);
        vm.expectRevert(OracleAdminGuard.NotApprovable.selector);
        g.approveQueued(address(oracle), d);
    }

    function test_approve_notQueued_reverts() public {
        bytes memory d = _setPrice(B, 300e18);
        vm.prank(second);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.NotQueued.selector, _id(d)));
        g.approveQueued(address(oracle), d);
    }

    function test_cancel_byGuardian() public {
        vm.prank(guardian);
        g.cancel(_id(far));
        assertEq(g.eta(_id(far)), 0);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.NotQueued.selector, _id(far)));
        g.execute(address(oracle), far);
    }

    function test_cancel_bySecondSafe() public {
        vm.prank(second);
        g.cancel(_id(far));
        assertEq(g.eta(_id(far)), 0);
    }

    function test_cancel_bySafe_reverts() public {
        vm.prank(safe);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.cancel(_id(far));
    }

    function test_cancel_unknown_reverts() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.NotQueued.selector, bytes32(uint256(1))));
        g.cancel(bytes32(uint256(1)));
    }

    // ── A6: role replacement ──
    function test_setGuardian_instant_bySafeOrSecond() public {
        address g2 = makeAddr("g2");
        vm.prank(safe);
        g.setGuardian(g2);
        assertEq(g.guardian(), g2);
        vm.prank(second);
        g.setGuardian(guardian);
        assertEq(g.guardian(), guardian);
    }

    function test_setGuardian_byGuardian_reverts() public {
        vm.prank(guardian);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.setGuardian(makeAddr("g2"));
    }

    function test_replaceSecondSafe_delayed_onlyGuardianCancels() public {
        bytes memory d = abi.encodeCall(OracleAdminGuard.setSecondSafe, (makeAddr("s2")));
        bytes32 id = keccak256(abi.encode(address(g), d));
        vm.prank(safe);
        g.submit(address(g), d);
        assertTrue(g.guardianOnlyCancel(id));
        vm.prank(second);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.cancel(id);
        vm.prank(guardian);
        g.cancel(id);
        assertEq(g.eta(id), 0);
    }

    function test_replaceSecondSafe_executes() public {
        address s2 = makeAddr("s2");
        bytes memory d = abi.encodeCall(OracleAdminGuard.setSecondSafe, (s2));
        vm.prank(safe);
        g.submit(address(g), d);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        g.execute(address(g), d);
        assertEq(g.secondSafe(), s2);
    }

    function test_selfSetters_directCall_reverts() public {
        vm.prank(safe);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.setSafe(safe);
        vm.prank(safe);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.setBackupKeeper(safe);
    }

    function test_replaceSafe_executes_oldSafeLosesPower() public {
        address s2 = makeAddr("safe2");
        bytes memory d = abi.encodeCall(OracleAdminGuard.setSafe, (s2));
        vm.prank(safe);
        g.submit(address(g), d);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        g.execute(address(g), d);
        assertEq(g.safe(), s2);
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        _submit(_setPrice(A, 100e18));
    }

    function test_failingQueuedCall_bubbles_andStaysQueued() public {
        bytes memory d = _setPrice(makeAddr("X"), 1e18); // unconfigured on the oracle
        _submit(d);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotConfigured.selector, makeAddr("X")));
        g.execute(address(oracle), d);
        assertTrue(_queued(d));
    }
}
