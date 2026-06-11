// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Hardening / finding-confirmation tests written during the EVM contract
///         review. These cover regimes the existing suite left untested and turn
///         the manual-reasoning findings into executable evidence.
contract PoppieEulerReviewTest is Test {
    PoppieEulerOracle oracle;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address aAdmin = address(0xA1);
    address user = address(0xCC);
    address constant UNIT = address(840);

    function setUp() public {
        oracle = new PoppieEulerOracle(admin, keeper, 3600, 86400);
    }

    function _arr(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _configureAndRegister(
        PoppieEulerAdapter adapter,
        MockERC20 t,
        uint256 cb,
        int256 price
    ) internal {
        _configureAndRegister(adapter, t, cb, cb, price);
    }

    function _configureAndRegister(
        PoppieEulerAdapter adapter,
        MockERC20 t,
        uint256 cb,
        uint256 cap,
        int256 price
    ) internal {
        uint256[] memory th = new uint256[](1);
        th[0] = cb;
        uint256[] memory caps = new uint256[](1);
        caps[0] = cap;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th, caps);
        uint8 dec = t.decimals();
        vm.prank(aAdmin);
        adapter.registerBase(address(t), dec);
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
        PoppieEulerAdapter adapter =
            new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 6);
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        _configureAndRegister(adapter, t, 0, 175.23e18);

        // exp = baseDec(18) + 18 - uoaDec(6) = 30
        // out = mulDiv(1e18, 175.23e18, 1e30) = 175.23e6
        uint256 got = adapter.getQuote(1e18, address(t), UNIT);
        assertEq(got, 175_230000); // 175.23 in 6 decimals
        assertEq(got, Math.mulDiv(1e18, uint256(int256(175.23e18)), 10 ** 30));
    }

    function test_getQuote_unitDecimals8_baseDecimals6() public {
        PoppieEulerAdapter adapter =
            new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 8);
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

        PoppieEulerAdapter adapter =
            new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, uoaDec);
        MockERC20 t = new MockERC20("F", "F", baseDec);
        _configureAndRegister(adapter, t, 0, price18);

        uint256 exp = uint256(baseDec) + 18 - uint256(uoaDec); // always >= 0
        uint256 expected = Math.mulDiv(inAmount, uint256(price18), 10 ** exp);
        assertEq(adapter.getQuote(inAmount, address(t), UNIT), expected);
    }

    // ---------------------------------------------------------------------
    // FINDING (Low, accepted): the circuit breaker bounds a SINGLE step, not
    // Cumulative deviation guard: multiple in-band pushes that compound
    // beyond the cumulative cap are now blocked.
    // ---------------------------------------------------------------------

    function test_circuitBreaker_cumulativeDriftIsBlocked() public {
        PoppieEulerAdapter adapter =
            new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 18);
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        _configureAndRegister(adapter, t, 5000, 100e18); // 50% per-step, 50% cumulative cap

        // First push: +40% (within both the 50% step breaker and 50% cumulative cap).
        int256[] memory p = new int256[](1);
        p[0] = 140e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);

        // Second push: another +40% from 140 -> 196. Total from anchor (100): +96%.
        // Exceeds the 50% cumulative cap.
        p[0] = 196e18;
        vm.prank(keeper);
        vm.expectRevert(); // CumulativeDeviationExceeded
        oracle.keeperPushPrices(_arr(address(t)), p);

        // Price stays at the first push value.
        assertEq(oracle.getPrice(address(t)), 140e18);
    }

    function test_circuitBreaker_cumulativeDriftResetsAfterWindow() public {
        PoppieEulerAdapter adapter =
            new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 18);
        MockERC20 t = new MockERC20("AAPLon", "AAPLon", 18);
        _configureAndRegister(adapter, t, 5000, 5000, 100e18); // explicit 50%/50%

        // Push +40% (within both guards).
        int256[] memory p = new int256[](1);
        p[0] = 140e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);

        // Wait for the anchor window to expire (86400s in test setup).
        vm.warp(block.timestamp + 86401);

        // Now another +40% from 140 -> 196 should succeed because the anchor
        // resets to 140 (the current lastPrice) at the start of this push.
        p[0] = 196e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);
        assertEq(oracle.getPrice(address(t)), 196e18);
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
        oracle.configureAssets(_arr(address(t)), th, th);
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

    function test_unregisterBase_neverRegistered_reverts() public {
        PoppieEulerAdapter adapter =
            new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 18);
        MockERC20 t = new MockERC20("X", "X", 18);
        (bool regBefore,) = adapter.getBaseInfo(address(t));
        assertFalse(regBefore);
        vm.prank(aAdmin);
        vm.expectRevert();
        adapter.unregisterBase(address(t));
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
        oracle.configureAssets(_arr(address(t)), th, th);
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
        oracle.configureAssets(_arr(address(t)), th, th);
        int256[] memory p = new int256[](1);
        p[0] = 100e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);
        // Read in the same block: block.timestamp - lastPriceTimestamp == 0.
        assertEq(oracle.getPrice(address(t)), 100e18);
    }
}
