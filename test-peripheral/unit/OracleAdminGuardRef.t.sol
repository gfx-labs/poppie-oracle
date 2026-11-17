// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P3Base} from "../lib/P3Base.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";

contract OracleAdminGuardRefTest is P3Base {
    function _pauseA() internal {
        vm.prank(guardian);
        g.pauseAssets(_one(A));
    }

    // ── A3: window reference ──
    function test_walkBlocked_sameTx() public {
        _submit(_setPrice(A, 105e18));
        bytes memory d = _setPrice(A, 110e18); // +4.76% from last, +10% from ref
        _submit(d);
        assertTrue(_queued(d));
        assertEq(_cfg(A).lastPrice, 105e18);
        (uint128 rp,) = g.ref(A);
        assertEq(rp, 100e18);
    }

    function test_walkBlocked_laterInWindow() public {
        _submit(_setPrice(A, 105e18));
        vm.warp(block.timestamp + DELAY - 1);
        bytes memory d = _setPrice(A, 106e18);
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_newWindow_usesLastPrice() public {
        _submit(_setPrice(A, 105e18));
        vm.warp(block.timestamp + DELAY);
        _submit(_setPrice(A, 110e18)); // within 5% of 105
        assertEq(_cfg(A).lastPrice, 110e18);
        (uint128 rp, uint40 st) = g.ref(A);
        assertEq(rp, 105e18);
        assertEq(st, block.timestamp);
    }

    function test_keeperPushes_doNotMoveRef() public {
        _submit(_setPrice(A, 104e18));
        vm.warp(block.timestamp + 1 hours);
        _push(A, 108e18); // keeper move within breaker
        bytes memory d = _setPrice(A, 108e18); // within 5% of last, not of ref(100)
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_seed_setsRef() public {
        _submit(_setPrice(C, 50e18));
        _submit(_setPrice(C, 52e18));
        assertEq(_cfg(C).lastPrice, 52e18);
        bytes memory d = _setPrice(C, 53e18); // > 52.5
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_delayedPrice_resetsRef() public {
        bytes memory far = _setPrice(A, 200e18);
        _submit(far);
        vm.warp(block.timestamp + DELAY);
        _exec(far);
        _submit(_setPrice(A, 205e18));
        assertEq(_cfg(A).lastPrice, 205e18);
    }

    // ── A4: pause recovery via prePausePrice ──
    function test_pauseRecovery_usesPrePause() public {
        vm.warp(block.timestamp + DELAY); // no active window
        _pauseA();
        assertEq(g.prePausePrice(A), 100e18);
        assertTrue(_cfg(A).paused);
        _submit(_setPrice(A, 103e18));
        assertEq(_cfg(A).lastPrice, 103e18);
        assertEq(g.prePausePrice(A), 0, "cleared on reseed");
        _push(A, 103e18); // keeper auto-unpauses
        assertFalse(_cfg(A).paused);
    }

    function test_pauseRecovery_outOfBand_queued() public {
        _pauseA();
        bytes memory d = _setPrice(A, 106e18);
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_pause_bySafeDirect_recordsPrePause() public {
        vm.prank(safe);
        g.pauseAssets(_one(B));
        assertEq(g.prePausePrice(B), 100e18);
    }

    function test_pause_onlySafeOrGuardian() public {
        vm.prank(second);
        vm.expectRevert();
        g.pauseAssets(_one(A));
    }

    function test_pausedNeverPriced_notSeedable() public {
        // C configured, unseeded; a pause leaves no pre-pause price -> reseed needs the delay
        vm.prank(guardian);
        g.pauseAssets(_one(C));
        bytes memory d = _setPrice(C, 1e18);
        _submit(d);
        assertTrue(_queued(d));
    }

    // ── A5: keeper-paused assets need delay or second-Safe approval ──
    function test_keeperPaused_secondSafeApproves() public {
        vm.prank(keeper);
        oracle.pauseAssets(_one(A));
        bytes memory d = _setPrice(A, 100e18);
        _submit(d);
        assertTrue(_queued(d));
        vm.prank(second);
        g.approveQueued(address(oracle), d);
        assertEq(_cfg(A).lastPrice, 100e18);
    }

    // ── fuzz: any same-timestamp sequence of Safe submits stays within band of the window ref ──
    function testFuzz_walkBounded(uint128[8] memory ps, uint8 pauseAt) public {
        uint256 ref0 = 100e18;
        for (uint256 i; i < ps.length; ++i) {
            if (i == pauseAt % 16 && !_cfg(A).paused) _pauseA();
            uint128 p = uint128(bound(ps[i], 1, 1000e18));
            _submitMaybeQueued(_setPrice(A, p));
            uint256 last = _cfg(A).lastPrice;
            if (last != 0) {
                uint256 diff = last > ref0 ? last - ref0 : ref0 - last;
                assertLe(diff * 10_000, BAND * ref0, "walked outside band");
            }
        }
    }

    function _submitMaybeQueued(bytes memory d) internal {
        if (_queued(d)) return; // pending duplicate would revert AlreadyQueued
        _submit(d);
    }
}
