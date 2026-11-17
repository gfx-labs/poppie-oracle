// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P3Base} from "../lib/P3Base.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {OracleAdminGuard} from "../../src/peripheral/OracleAdminGuard.sol";

contract OracleAdminGuardClassifyTest is P3Base {
    /// @dev Lands `data` through the delay so the next classification sees new state.
    function _land(bytes memory data) internal {
        _submit(data);
        if (_queued(data)) {
            vm.warp(block.timestamp + DELAY);
            _exec(data);
        }
    }

    function test_onlySafeSubmits() public {
        vm.expectRevert(OracleAdminGuard.Unauthorized.selector);
        g.submit(address(oracle), _setPrice(A, 100e18));
    }

    // ── pauseAssets / configureAssets ──
    function test_pauseAssets_viaSubmit_instant_recordsPrePause() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.pauseAssets, (_one(A))));
        assertTrue(_cfg(A).paused);
        assertEq(g.prePausePrice(A), 100e18);
    }

    function test_configureAssets_instant() public {
        address d = makeAddr("D");
        uint16[] memory z = new uint16[](1);
        uint16[] memory cum = new uint16[](1);
        cum[0] = 100;
        _submit(abi.encodeCall(IPoppieEulerOracle.configureAssets, (_one(d), z, cum)));
        assertTrue(_cfg(d).configured);
    }

    // ── adminSetPrice ──
    function test_setPrice_seedNeverPriced_instant() public {
        _submit(_setPrice(C, 42e18));
        assertEq(_cfg(C).lastPrice, 42e18);
    }

    function test_setPrice_inBand_instant_boundary() public {
        _submit(_setPrice(A, 105e18)); // exactly +5%
        assertEq(_cfg(A).lastPrice, 105e18);
        _submit(_setPrice(B, 95e18)); // exactly -5%
        assertEq(_cfg(B).lastPrice, 95e18);
    }

    function test_setPrice_outOfBand_queued() public {
        bytes memory d = _setPrice(A, 105e18 + 1);
        _submit(d);
        assertEq(_cfg(A).lastPrice, 100e18);
        assertEq(g.eta(_id(d)), block.timestamp + DELAY);
        bytes memory d2 = _setPrice(B, 95e18 - 1);
        _submit(d2);
        assertTrue(_queued(d2));
    }

    function test_setPrice_unconfigured_queued() public {
        bytes memory d = _setPrice(makeAddr("X"), 1e18);
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_setPrice_keeperPaused_noPrePause_queued() public {
        // A5: assets paused by the keeper path have no pre-pause record.
        vm.prank(keeper);
        oracle.pauseAssets(_one(A));
        bytes memory d = _setPrice(A, 100e18);
        _submit(d);
        assertTrue(_queued(d));
    }

    // ── setAssetThresholds ──
    function test_thresholds_tighten_instant() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 500, 1000)));
        assertEq(_cfg(A).circuitBreakerThreshold, 500);
        assertEq(_cfg(A).cumulativeDeviationCap, 1000);
    }

    function test_thresholds_equal_instant() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 1000, 2000)));
        assertFalse(_queued(abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 1000, 2000))));
    }

    function test_thresholds_disableBreaker_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 0, 2000));
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_thresholds_loosenBreaker_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 1001, 2000));
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_thresholds_loosenCum_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 1000, 2001));
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_thresholds_enableBreakerFromZero_instant() public {
        _land(abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 0, 2000)));
        assertEq(_cfg(A).circuitBreakerThreshold, 0);
        _submit(abi.encodeCall(IPoppieEulerOracle.setAssetThresholds, (A, 9000, 2000)));
        assertEq(_cfg(A).circuitBreakerThreshold, 9000);
    }

    // ── setMaxPriceAge ──
    function test_maxAge_tighten_instant() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (1 days)));
        assertEq(oracle.maxPriceAge(), 1 days);
    }

    function test_maxAge_loosen_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (3 days + 1));
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_maxAge_disable_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (0));
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_maxAge_enableFromZero_instant() public {
        _land(abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (0)));
        assertEq(oracle.maxPriceAge(), 0);
        _submit(abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (30 days)));
        assertEq(oracle.maxPriceAge(), 30 days);
    }

    // ── setAssetMaxPriceAge (eff(v) = v != 0 ? v : global) ──
    function test_assetMaxAge_tighten_instant() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 1 days)));
        assertEq(_cfg(A).maxPriceAge, 1 days);
    }

    function test_assetMaxAge_zeroEqualsGlobal_instant() public {
        // old 0 -> eff 3d; new 0 -> eff 3d: not loosening
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 0));
        _submit(d);
        assertFalse(_queued(d));
    }

    function test_assetMaxAge_loosen_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 4 days));
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_assetMaxAge_clearOverrideLoosens_queued() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 1 days)));
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 0)); // eff 1d -> 3d
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_assetMaxAge_globalZero_clearIsDisable_queued() public {
        _land(abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, (0)));
        _submit(abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 1 days))); // eff 0 -> 1d: instant
        assertEq(_cfg(A).maxPriceAge, 1 days);
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (A, 0)); // eff 1d -> 0
        _submit(d);
        assertTrue(_queued(d));
    }

    // ── setAnchorWindow / setKeeper / transferAdmin / acceptAdmin ──
    function test_anchorWindow_alwaysQueued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setAnchorWindow, (1 hours)); // even tightening
        _submit(d);
        assertTrue(_queued(d));
        assertEq(oracle.anchorWindow(), 1 days);
    }

    function test_setKeeper_backup_instant() public {
        _submit(abi.encodeCall(IPoppieEulerOracle.setKeeper, (backup)));
        assertEq(oracle.keeper(), backup);
    }

    function test_setKeeper_other_queued() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setKeeper, (makeAddr("evil")));
        _submit(d);
        assertTrue(_queued(d));
        assertEq(oracle.keeper(), keeper);
    }

    function test_transferAdmin_longDelay() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.transferAdmin, (safe));
        _submit(d);
        assertEq(g.eta(_id(d)), block.timestamp + LONG);
    }

    function test_acceptAdmin_viaSubmit_reverts() public {
        vm.prank(safe);
        vm.expectRevert(OracleAdminGuard.UseAcceptOracleAdmin.selector);
        g.submit(address(oracle), abi.encodeCall(IPoppieEulerOracle.acceptAdmin, ()));
    }

    // ── other selectors / targets ──
    function test_unknownSelector_queued() public {
        bytes memory d = abi.encodeWithSignature("doesNotExist()");
        _submit(d);
        assertTrue(_queued(d));
    }

    function test_otherTarget_queued() public {
        address t = makeAddr("P4");
        bytes memory d = abi.encodeWithSignature("setBudget(uint32,uint32)", 1, 1);
        vm.prank(safe);
        g.submit(t, d);
        assertEq(g.eta(keccak256(abi.encode(t, d))), block.timestamp + DELAY);
    }

    function test_selfConfig_queued() public {
        bytes memory d = abi.encodeCall(OracleAdminGuard.setSafe, (makeAddr("newSafe")));
        vm.prank(safe);
        g.submit(address(g), d);
        assertEq(g.safe(), safe);
        assertEq(g.eta(keccak256(abi.encode(address(g), d))), block.timestamp + DELAY);
    }
}
