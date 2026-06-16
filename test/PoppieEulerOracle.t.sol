// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PoppieEulerOracleTest is Test {
    // Mirror events for expectEmit assertions
    event PricesRefreshed(address[] assets);
    event AssetConfigured(address indexed asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap);
    event AssetThresholdsUpdated(address indexed asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event AdminPriceForced(address indexed asset, uint128 price);
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge, uint256 anchorWindow);

    PoppieEulerOracle oracle;
    MockERC20 token;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address user = address(0xCC);

    uint256 constant MAX_AGE = 3600;
    uint16 constant CB = 5000; // 50% bps
    uint128 constant SEED_PRICE = 100e18;

    function setUp() public {
        token = new MockERC20("AAPLon", "AAPLon", 18);
        oracle = new PoppieEulerOracle(admin, keeper, MAX_AGE, 86400);

        address[] memory a = new address[](1);
        uint16[] memory t = new uint16[](1);
        a[0] = address(token);
        t[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(a, t, t);

        // seed an initial reference price so keeper pushes are bounded by the guards.
        // tests that exercise the unseeded state construct their own asset.
        vm.prank(admin);
        oracle.adminSetPrice(address(token), SEED_PRICE);
    }

    function _arr(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _push(uint128 price) internal {
        uint128[] memory p = new uint128[](1);
        p[0] = price;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    // --- Constructor ---

    function test_constructor() public view {
        assertEq(oracle.admin(), admin);
        assertEq(oracle.keeper(), keeper);
        assertEq(oracle.maxPriceAge(), MAX_AGE);
    }

    function test_constructor_emitsOracleDeployed() public {
        vm.expectEmit(true, true, false, true);
        emit OracleDeployed(admin, keeper, MAX_AGE, 86400);
        new PoppieEulerOracle(admin, keeper, MAX_AGE, 86400);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(IPoppieEulerOracle.ZeroAddress.selector);
        new PoppieEulerOracle(address(0), keeper, MAX_AGE, 86400);
    }

    function test_constructor_revert_zeroKeeper() public {
        vm.expectRevert(IPoppieEulerOracle.ZeroAddress.selector);
        new PoppieEulerOracle(admin, address(0), MAX_AGE, 86400);
    }

    // --- configureAssets ---

    function test_configureAssets() public {
        // configure a fresh asset and confirm initial state has no stored price
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory th = new uint16[](1);
        th[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th, th);

        IPoppieEulerOracle.AssetConfig memory c = oracle.getAssetConfig(address(t2));
        assertTrue(c.configured);
        assertEq(c.circuitBreakerThreshold, CB);
        assertEq(c.lastPrice, 0);
    }

    function test_configureAssets_emitsEvent() public {
        MockERC20 t2 = new MockERC20("Y", "Y", 18);
        uint16[] memory th = new uint16[](1);
        th[0] = CB;
        vm.expectEmit(true, false, false, true);
        emit AssetConfigured(address(t2), CB, CB);
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th, th);
    }

    function test_configureAssets_revert_notAdmin() public {
        address[] memory a = new address[](1);
        uint16[] memory t = new uint16[](1);
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.OnlyAdmin.selector);
        oracle.configureAssets(a, t, t);
    }

    function test_configureAssets_revert_alreadyConfigured() public {
        uint16[] memory t = new uint16[](1);
        t[0] = CB;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetAlreadyConfigured.selector, address(token)));
        oracle.configureAssets(_arr(address(token)), t, t);
    }

    function test_configureAssets_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        uint16[] memory t = new uint16[](1);
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.configureAssets(a, t, t);
    }

    // --- keeperPushPrices ---

    function test_push_basic() public {
        // push 125e18 from seed 100e18: +25%, within 50% breaker and cumulative cap.
        _push(125e18);
        assertEq(oracle.getPrice(address(token)), 125e18);
    }

    function test_push_emitsPricesRefreshed() public {
        uint128[] memory p = new uint128[](1);
        p[0] = 125e18;
        vm.expectEmit(false, false, false, true);
        emit PricesRefreshed(_arr(address(token)));
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_notKeeper() public {
        uint128[] memory p = new uint128[](1);
        p[0] = 1e18;
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.OnlyKeeper.selector);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_invalidPrice() public {
        uint128[] memory p = new uint128[](1);
        p[0] = 0;
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.InvalidPrice.selector);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_notConfigured() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint128[] memory p = new uint128[](1);
        p[0] = 1e18;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotConfigured.selector, address(t2)));
        oracle.keeperPushPrices(_arr(address(t2)), p);
    }

    function test_push_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        uint128[] memory p = new uint128[](1);
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.keeperPushPrices(a, p);
    }

    // --- Circuit breaker ---

    function test_cb_withinThreshold() public {
        _push(100e18);
        _push(140e18); // +40%, within 50%
        assertEq(oracle.getPrice(address(token)), 140e18);
    }

    function test_cb_exceedsThreshold() public {
        _push(100e18);
        uint128[] memory p = new uint128[](1);
        p[0] = 160e18; // +60%, exceeds 50%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(token), 6000, CB));
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_unseededAsset() public {
        // a freshly configured asset rejects keeper pushes until admin seeds a price.
        // this prevents the first push from bypassing both guards.
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory th = new uint16[](1);
        th[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th, th);

        uint128[] memory p = new uint128[](1);
        p[0] = 1_000_000e18;
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.PriceNotInitialized.selector);
        oracle.keeperPushPrices(_arr(address(t2)), p);
    }

    function test_cb_zeroThresholdDisablesBreaker() public {
        // setting the per-push circuit breaker to 0 disables it, but the cumulative
        // cap must remain non-zero (enforced by setAssetThresholds). A push within
        // the cumulative cap is allowed even with the per-push breaker disabled.
        vm.prank(admin);
        oracle.setAssetThresholds(address(token), 0, CB);
        _push(140e18); // +40% from seed 100, within 50% cumulative cap, no per-push limit
        assertEq(oracle.getPrice(address(token)), 140e18);
    }

    // --- Anchor rotation (A-1 / D-2): after `anchorWindow` elapses, the next
    //     keeper push must rotate the anchor to the previous `lastPrice` and
    //     evaluate drift against that freshly-rotated reference. ---

    function test_anchor_rotatesToPreviousLastPriceAfterWindow() public {
        // Seed = 100 (from setUp). First push: +40% to 140. Anchor still 100.
        _push(140e18);
        IPoppieEulerOracle.AssetConfig memory cfgBefore = oracle.getAssetConfig(address(token));
        assertEq(cfgBefore.anchorPrice, 100e18, "anchor unchanged before window expiry");
        assertEq(cfgBefore.lastPrice, 140e18);

        // Advance past the rolling-anchor window (86400s configured in setUp).
        vm.warp(block.timestamp + 86401);

        // Next push: +40% from 140 -> 196. This would be +96% from the original
        // anchor 100 and exceed the 50% cumulative cap, but the rotation rebases
        // the anchor to 140 (the previous lastPrice) so +40% is in-band.
        _push(196e18);

        IPoppieEulerOracle.AssetConfig memory cfgAfter = oracle.getAssetConfig(address(token));
        assertEq(cfgAfter.anchorPrice, 140e18, "anchor rotated to previous lastPrice");
        assertEq(cfgAfter.lastPrice, 196e18);
        assertEq(uint256(cfgAfter.anchorTimestamp), block.timestamp, "anchor timestamp stamped with push ts");
    }

    function test_anchor_doesNotRotateWithinWindow() public {
        // Two pushes within the window — anchor must not move.
        _push(120e18);
        vm.warp(block.timestamp + 86400); // exactly at window, not past it
        _push(130e18);
        IPoppieEulerOracle.AssetConfig memory cfg = oracle.getAssetConfig(address(token));
        assertEq(cfg.anchorPrice, 100e18, "anchor frozen within window");
    }

    function test_anchor_zeroWindowDisablesRotation() public {
        // Set anchorWindow = 0. Anchor must never rotate, even far in the future.
        vm.prank(admin);
        oracle.setAnchorWindow(0);

        _push(140e18); // +40% from seed 100, in-band
        vm.warp(block.timestamp + 365 days);

        // Anchor is still the seed (100). A +40% push from 140 would be +96% from
        // the frozen anchor and trip the cumulative cap.
        uint128[] memory p = new uint128[](1);
        p[0] = 196e18;
        vm.prank(keeper);
        vm.expectRevert(); // CumulativeDeviationExceeded
        oracle.keeperPushPrices(_arr(address(token)), p);

        IPoppieEulerOracle.AssetConfig memory cfg = oracle.getAssetConfig(address(token));
        assertEq(cfg.anchorPrice, 100e18, "anchor never rotates when window = 0");
    }

    function test_setAssetThresholds_revert_zeroCumulativeCap() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        oracle.setAssetThresholds(address(token), CB, 0);
    }

    function test_configureAssets_revert_zeroCumulativeCap() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory cb = new uint16[](1);
        cb[0] = CB;
        uint16[] memory cap = new uint16[](1);
        cap[0] = 0;
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        oracle.configureAssets(_arr(address(t2)), cb, cap);
    }

    // --- A-4: bps caps must be <= 10000 ---

    function test_configureAssets_revert_circuitBreakerExceedsBps() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory cb = new uint16[](1);
        cb[0] = 10_001;
        uint16[] memory cap = new uint16[](1);
        cap[0] = CB;
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        oracle.configureAssets(_arr(address(t2)), cb, cap);
    }

    function test_configureAssets_revert_cumulativeCapExceedsBps() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory cb = new uint16[](1);
        cb[0] = CB;
        uint16[] memory cap = new uint16[](1);
        cap[0] = 10_001;
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        oracle.configureAssets(_arr(address(t2)), cb, cap);
    }

    function test_configureAssets_acceptsExactlyMaxBps() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory cb = new uint16[](1);
        cb[0] = 10_000;
        uint16[] memory cap = new uint16[](1);
        cap[0] = 10_000;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), cb, cap);
        // no revert
    }

    function test_setAssetThresholds_revert_circuitBreakerExceedsBps() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        oracle.setAssetThresholds(address(token), 10_001, CB);
    }

    function test_setAssetThresholds_revert_cumulativeCapExceedsBps() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        oracle.setAssetThresholds(address(token), CB, 10_001);
    }

    function test_setAssetThresholds_acceptsExactlyMaxBps() public {
        vm.prank(admin);
        oracle.setAssetThresholds(address(token), 10_000, 10_000);
        IPoppieEulerOracle.AssetConfig memory cfg = oracle.getAssetConfig(address(token));
        assertEq(cfg.circuitBreakerThreshold, 10_000);
        assertEq(cfg.cumulativeDeviationCap, 10_000);
    }

    // --- A-5: empty batches revert ---

    function test_configureAssets_revert_emptyArrays() public {
        address[] memory a = new address[](0);
        uint16[] memory t = new uint16[](0);
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.configureAssets(a, t, t);
    }

    function test_keeperPushPrices_revert_emptyArrays() public {
        address[] memory a = new address[](0);
        uint128[] memory p = new uint128[](0);
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.keeperPushPrices(a, p);
    }

    function test_pauseAssets_revert_emptyArrays() public {
        address[] memory a = new address[](0);
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.pauseAssets(a);
    }

    // --- getPrice staleness ---

    function test_getPrice_revert_uninitialized() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        uint16[] memory th = new uint16[](1);
        th[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th, th);
        vm.expectRevert(IPoppieEulerOracle.PriceNotInitialized.selector);
        oracle.getPrice(address(t2));
    }

    function test_getPrice_revert_stale() public {
        _push(100e18);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        oracle.getPrice(address(token));
    }

    function test_getPrice_freshAtBoundary() public {
        _push(100e18);
        vm.warp(block.timestamp + MAX_AGE); // exactly at limit, still fresh
        assertEq(oracle.getPrice(address(token)), 100e18);
    }

    function test_getPrice_zeroMaxAgeDisablesGuard() public {
        vm.prank(admin);
        oracle.setMaxPriceAge(0);
        _push(100e18);
        vm.warp(block.timestamp + 365 days);
        assertEq(oracle.getPrice(address(token)), 100e18); // never stale
    }

    // --- adminSetPrice (recovery) ---

    function test_adminSetPrice_bypassesBreaker() public {
        _push(100e18);
        // a +900% move the keeper could never push
        vm.expectEmit(true, false, false, true);
        emit AdminPriceForced(address(token), 1000e18);
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 1000e18);
        assertEq(oracle.getPrice(address(token)), 1000e18);
    }

    function test_adminSetPrice_refreshesStaleness() public {
        _push(100e18);
        vm.warp(block.timestamp + MAX_AGE + 1); // now stale
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 120e18);
        assertEq(oracle.getPrice(address(token)), 120e18); // fresh again
    }

    function test_adminSetPrice_revert_notAdmin() public {
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.OnlyAdmin.selector);
        oracle.adminSetPrice(address(token), 1e18);
    }

    function test_adminSetPrice_revert_invalidPrice() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.InvalidPrice.selector);
        oracle.adminSetPrice(address(token), 0);
    }

    function test_adminSetPrice_revert_notConfigured() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotConfigured.selector, address(t2)));
        oracle.adminSetPrice(address(t2), 1e18);
    }

    function test_adminSetPrice_multipleAssets() public {
        MockERC20 t2 = new MockERC20("Y", "Y", 18);
        uint16[] memory th = new uint16[](1);
        th[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th, th);

        vm.startPrank(admin);
        oracle.adminSetPrice(address(token), 50e18);
        oracle.adminSetPrice(address(t2), 75e18);
        vm.stopPrank();

        assertEq(oracle.getPrice(address(token)), 50e18);
        assertEq(oracle.getPrice(address(t2)), 75e18);
    }

    // --- admin setters ---

    function test_setKeeper() public {
        vm.expectEmit(false, false, false, true);
        emit KeeperUpdated(keeper, address(0xDD));
        vm.prank(admin);
        oracle.setKeeper(address(0xDD));
        assertEq(oracle.keeper(), address(0xDD));
    }

    function test_setKeeper_revert_zero() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.ZeroAddress.selector);
        oracle.setKeeper(address(0));
    }

    function test_transferAdmin_twoStep() public {
        // step 1: current admin proposes
        vm.expectEmit(true, true, false, true);
        emit AdminTransferStarted(admin, address(0xEE));
        vm.prank(admin);
        oracle.transferAdmin(address(0xEE));
        assertEq(oracle.admin(), admin); // not changed yet
        assertEq(oracle.pendingAdmin(), address(0xEE));

        // step 2: pending admin accepts
        vm.expectEmit(true, true, false, true);
        emit AdminTransferred(admin, address(0xEE));
        vm.prank(address(0xEE));
        oracle.acceptAdmin();
        assertEq(oracle.admin(), address(0xEE));
        assertEq(oracle.pendingAdmin(), address(0));
    }

    function test_transferAdmin_revert_zero() public {
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.ZeroAddress.selector);
        oracle.transferAdmin(address(0));
    }

    function test_acceptAdmin_revert_notPending() public {
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.NoPendingAdmin.selector);
        oracle.acceptAdmin();
    }

    function test_transferAdmin_overwritesPending() public {
        vm.prank(admin);
        oracle.transferAdmin(address(0xAA));
        vm.prank(admin);
        oracle.transferAdmin(address(0xBB));
        assertEq(oracle.pendingAdmin(), address(0xBB));

        // old pending can no longer accept
        vm.prank(address(0xAA));
        vm.expectRevert(IPoppieEulerOracle.NoPendingAdmin.selector);
        oracle.acceptAdmin();

        // new pending can
        vm.prank(address(0xBB));
        oracle.acceptAdmin();
        assertEq(oracle.admin(), address(0xBB));
    }

    function test_setMaxPriceAge() public {
        vm.expectEmit(false, false, false, true);
        emit MaxPriceAgeUpdated(MAX_AGE, 7200);
        vm.prank(admin);
        oracle.setMaxPriceAge(7200);
        assertEq(oracle.maxPriceAge(), 7200);
    }

    function test_setAssetThresholds() public {
        vm.expectEmit(true, false, false, true);
        emit AssetThresholdsUpdated(address(token), 1000, 2000);
        vm.prank(admin);
        oracle.setAssetThresholds(address(token), 1000, 2000);
        IPoppieEulerOracle.AssetConfig memory cfg = oracle.getAssetConfig(address(token));
        assertEq(cfg.circuitBreakerThreshold, 1000);
        assertEq(cfg.cumulativeDeviationCap, 2000);
    }

    function test_setAssetThresholds_revert_notConfigured() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotConfigured.selector, address(t2)));
        oracle.setAssetThresholds(address(t2), 1000, 2000);
    }

    // --- pause / unpause ---

    function test_pauseAssets_keeper() public {
        _push(100e18);
        // keeper pauses
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // getPrice reverts
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_pauseAssets_admin() public {
        _push(100e18);
        vm.prank(admin);
        oracle.pauseAssets(_arr(address(token)));
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_pauseAssets_revert_notKeeperOrAdmin() public {
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.OnlyKeeperOrAdmin.selector);
        oracle.pauseAssets(_arr(address(token)));
    }

    function test_pauseAssets_revert_alreadyPaused() public {
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetAlreadyPaused.selector, address(token)));
        oracle.pauseAssets(_arr(address(token)));
    }

    function test_pause_zerosAllPriceState() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        IPoppieEulerOracle.AssetConfig memory cfg = oracle.getAssetConfig(address(token));
        // all price state is zeroed — no stale values
        assertEq(cfg.lastPrice, 0);
        assertEq(cfg.lastPriceTimestamp, 0);
        assertEq(cfg.anchorPrice, 0);
        assertEq(cfg.anchorTimestamp, 0);
        // config preserved
        assertTrue(cfg.configured);
        assertTrue(cfg.paused);
        assertEq(cfg.circuitBreakerThreshold, CB);
    }

    function test_pause_keeperCannotUnpauseWithoutAdminReference() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // keeper tries to push — lastPrice is 0 (admin hasn't set reference)
        uint128[] memory p = new uint128[](1);
        p[0] = 101e18;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, address(token)));
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_pause_keeperUnpausesAfterAdminReference() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // admin sets recovery reference
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 105e18);
        // still paused — getPrice reverts
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, address(token)));
        oracle.getPrice(address(token));
        // keeper pushes in-band price → auto-unpauses
        uint128[] memory p = new uint128[](1);
        p[0] = 106e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
        // now live
        assertEq(oracle.getPrice(address(token)), 106e18);
        assertFalse(oracle.getAssetConfig(address(token)).paused);
    }

    function test_pause_keeperRejectsOutOfBandEvenWithReference() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 100e18);
        // keeper pushes way out of band
        uint128[] memory p = new uint128[](1);
        p[0] = 200e18;
        vm.prank(keeper);
        vm.expectRevert(); // CircuitBreakerTriggered
        oracle.keeperPushPrices(_arr(address(token)), p);
        // still paused
        assertTrue(oracle.getAssetConfig(address(token)).paused);
    }

    function test_pause_adminSetPriceDoesNotUnpause() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 200e18);
        // still paused
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, address(token)));
        oracle.getPrice(address(token));
        assertTrue(oracle.getAssetConfig(address(token)).paused);
    }

    function test_pause_fullRecoveryFlow() public {
        _push(100e18);
        // 1. corporate action — keeper pauses (price zeroed)
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        assertEq(oracle.getAssetConfig(address(token)).lastPrice, 0);
        // 2. admin reviews and sets post-event reference (still paused)
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 150e18);
        assertTrue(oracle.getAssetConfig(address(token)).paused);
        // 3. keeper pushes validated price → auto-unpauses
        uint128[] memory p = new uint128[](1);
        p[0] = 152e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
        // 4. asset is live with keeper's validated price
        assertEq(oracle.getPrice(address(token)), 152e18);
        assertFalse(oracle.getAssetConfig(address(token)).paused);
    }
}
