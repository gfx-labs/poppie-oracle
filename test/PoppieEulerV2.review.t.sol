// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracleV2} from "../src/PoppieEulerOracleV2.sol";
import {PoppieEulerAdapterV2} from "../src/PoppieEulerAdapterV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Hardening / finding-confirmation tests written during the EVM contract
///         review. These cover regimes the existing suite left untested and turn
///         the manual-reasoning findings into executable evidence.
contract PoppieEulerV2ReviewTest is Test {
    PoppieEulerOracleV2 oracle;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address aAdmin = address(0xA1);
    address user = address(0xCC);
    address constant UNIT = address(840);

    function setUp() public {
        oracle = new PoppieEulerOracleV2(admin, keeper, 3600);
    }

    function _arr(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _configureAndRegister(
        PoppieEulerAdapterV2 adapter,
        MockERC20 t,
        uint256 cb,
        int256 price
    ) internal {
        uint256[] memory th = new uint256[](1);
        th[0] = cb;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th);
        vm.prank(aAdmin);
        adapter.registerBase(address(t));
        int256[] memory p = new int256[](1);
        p[0] = price;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);
    }

    // ---------------------------------------------------------------------
    // GAP: unitOfAccountDecimals < 18 (the divide path with quoteDec < 18).
    // All existing tests use UoA decimals == 18. Confirm exactness for 6/8.
    // ---------------------------------------------------------------------

    function test_getQuote_unitDecimals6() public {
        PoppieEulerAdapterV2 adapter =
            new PoppieEulerAdapterV2(address(oracle), aAdmin, UNIT, 6);
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        _configureAndRegister(adapter, t, 0, 175.23e18);

        // exp = baseDec(18) + 18 - uoaDec(6) = 30
        // out = mulDiv(1e18, 175.23e18, 1e30) = 175.23e6
        uint256 got = adapter.getQuote(1e18, address(t), UNIT);
        assertEq(got, 175_230000); // 175.23 in 6 decimals
        assertEq(got, Math.mulDiv(1e18, uint256(int256(175.23e18)), 10 ** 30));
    }

    function test_getQuote_unitDecimals8_baseDecimals6() public {
        PoppieEulerAdapterV2 adapter =
            new PoppieEulerAdapterV2(address(oracle), aAdmin, UNIT, 8);
        MockERC20 t = new MockERC20("USDCon", "USDCon", 6);
        _configureAndRegister(adapter, t, 0, 1e18); // $1

        // exp = 6 + 18 - 8 = 16; out = mulDiv(1e6, 1e18, 1e16) = 1e8
        assertEq(adapter.getQuote(1e6, address(t), UNIT), 1e8);
    }

    function testFuzz_getQuote_matchesReference_anyUnitDecimals(
        uint8 uoaDec,
        uint8 baseDec,
        uint256 inAmount,
        uint256 priceRaw
    ) public {
        uoaDec = uint8(bound(uoaDec, 0, 18));
        baseDec = uint8(bound(baseDec, 0, 18));
        int256 price18 = int256(bound(priceRaw, 1e14, 1e25));
        inAmount = bound(inAmount, 0, 1e12 * (10 ** uint256(baseDec)));

        PoppieEulerAdapterV2 adapter =
            new PoppieEulerAdapterV2(address(oracle), aAdmin, UNIT, uoaDec);
        MockERC20 t = new MockERC20("F", "F", baseDec);
        _configureAndRegister(adapter, t, 0, price18);

        uint256 exp = uint256(baseDec) + 18 - uint256(uoaDec); // always >= 0
        uint256 expected = Math.mulDiv(inAmount, uint256(price18), 10 ** exp);
        assertEq(adapter.getQuote(inAmount, address(t), UNIT), expected);
    }

    // ---------------------------------------------------------------------
    // FINDING (Low, accepted): the circuit breaker bounds a SINGLE step, not
    // cumulative drift. A keeper can walk the price far past the per-asset
    // threshold across several in-band pushes. Documented in oracle.md Trust
    // Model; encoded here so the behavior is explicit and regression-guarded.
    // ---------------------------------------------------------------------

    function test_circuitBreaker_cumulativeDriftIsUnbounded() public {
        PoppieEulerAdapterV2 adapter =
            new PoppieEulerAdapterV2(address(oracle), aAdmin, UNIT, 18);
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        _configureAndRegister(adapter, t, 5000, 100e18); // 50% per-step breaker

        // Each push is +40% (within the 50% step breaker) yet compounds well
        // beyond 50% cumulatively.
        int256 cur = 100e18;
        for (uint256 i = 0; i < 5; i++) {
            cur = (cur * 140) / 100;
            int256[] memory p = new int256[](1);
            p[0] = cur;
            vm.prank(keeper);
            oracle.keeperPushPrices(_arr(address(t)), p);
        }
        // 100 -> ~537.8 (5 x +40%), a >430% move executed entirely in-band.
        assertEq(oracle.getPrice(address(t)), cur);
        assertGt(cur, 500e18);
    }

    // ---------------------------------------------------------------------
    // FINDING (Low): setMaxPriceAge(0) silently disables the freshness guard,
    // the single most important on-chain safety property. Confirm a stale
    // price reads fine once the guard is off.
    // ---------------------------------------------------------------------

    function test_setMaxPriceAge_zero_disablesFreshnessEntirely() public {
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        uint256[] memory th = new uint256[](1);
        th[0] = 0;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th);
        int256[] memory p = new int256[](1);
        p[0] = 100e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);

        vm.prank(admin);
        oracle.setMaxPriceAge(0);
        vm.warp(block.timestamp + 3650 days); // 10 years
        // No revert: an arbitrarily stale price is served as fresh.
        assertEq(oracle.getPrice(address(t)), 100e18);
    }

    // ---------------------------------------------------------------------
    // FINDING (Info): unregisterBase does not require the base to be
    // registered; it deletes unconditionally and emits BaseUnregistered even
    // for a never-registered base (misleading log). Confirm it does not revert.
    // ---------------------------------------------------------------------

    function test_unregisterBase_neverRegistered_doesNotRevert() public {
        PoppieEulerAdapterV2 adapter =
            new PoppieEulerAdapterV2(address(oracle), aAdmin, UNIT, 18);
        MockERC20 t = new MockERC20("X", "X", 18);
        (bool regBefore,) = adapter.getBaseInfo(address(t));
        assertFalse(regBefore);
        // Emits BaseUnregistered despite the base never having been registered.
        vm.prank(aAdmin);
        adapter.unregisterBase(address(t)); // no revert
        (bool regAfter,) = adapter.getBaseInfo(address(t));
        assertFalse(regAfter);
    }

    // ---------------------------------------------------------------------
    // FINDING (Low): adminSetPrice has no magnitude sanity bound. A fat-finger
    // value is written directly and served to Euler on the next read.
    // ---------------------------------------------------------------------

    function test_adminSetPrice_acceptsAbsurdValue_noSanityBound() public {
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        uint256[] memory th = new uint256[](1);
        th[0] = 5000;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th);
        int256[] memory p = new int256[](1);
        p[0] = 100e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);

        // A 1e30 ("$1 trillion-per-token") fat-finger is accepted with no bound.
        vm.prank(admin);
        oracle.adminSetPrice(address(t), 1e30);
        assertEq(oracle.getPrice(address(t)), 1e30);
    }

    // ---------------------------------------------------------------------
    // Sanity: the timestamp subtraction flagged by Slither/Semgrep cannot
    // underflow, because lastPriceTimestamp is only ever set to block.timestamp
    // and block.timestamp is monotonic. Confirm getPrice never reverts from the
    // subtraction itself at the exact write block.
    // ---------------------------------------------------------------------

    function test_getPrice_noUnderflow_sameBlock() public {
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        uint256[] memory th = new uint256[](1);
        th[0] = 0;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th);
        int256[] memory p = new int256[](1);
        p[0] = 100e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);
        // Read in the same block: block.timestamp - lastPriceTimestamp == 0.
        assertEq(oracle.getPrice(address(t)), 100e18);
    }
}
