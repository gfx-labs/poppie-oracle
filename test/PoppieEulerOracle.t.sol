// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PoppieEulerOracleTest is Test {
    // Mirror events for expectEmit assertions
    event PricesRefreshed(address[] assets);
    event AssetConfigured(address indexed asset, uint256 circuitBreakerThreshold, uint256 cumulativeDeviationCap);
    event AssetThresholdsUpdated(address indexed asset, uint256 circuitBreakerThreshold, uint256 cumulativeDeviationCap);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event AdminPriceForced(address indexed asset, int256 price);
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge, uint256 anchorWindow);

    PoppieEulerOracle oracle;
    MockERC20 token;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address user = address(0xCC);

    uint256 constant MAX_AGE = 3600;
    uint256 constant CB = 5000; // 50% bps

    function setUp() public {
        token = new MockERC20("AAPLon", "AAPLon", 18);
        oracle = new PoppieEulerOracle(admin, keeper, MAX_AGE, 86400);

        address[] memory a = new address[](1);
        uint256[] memory t = new uint256[](1);
        a[0] = address(token);
        t[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(a, t, t);
    }

    function _arr(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _push(int256 price) internal {
        int256[] memory p = new int256[](1);
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

    function test_configureAssets() public view {
        IPoppieEulerOracle.AssetConfig memory c = oracle.getAssetConfig(address(token));
        assertTrue(c.configured);
        assertEq(c.circuitBreakerThreshold, CB);
        assertEq(c.lastPrice, 0);
    }

    function test_configureAssets_emitsEvent() public {
        MockERC20 t2 = new MockERC20("Y", "Y", 18);
        uint256[] memory th = new uint256[](1);
        th[0] = CB;
        vm.expectEmit(true, false, false, true);
        emit AssetConfigured(address(t2), CB, CB);
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th, th);
    }

    function test_configureAssets_revert_notAdmin() public {
        address[] memory a = new address[](1);
        uint256[] memory t = new uint256[](1);
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.OnlyAdmin.selector);
        oracle.configureAssets(a, t, t);
    }

    function test_configureAssets_revert_alreadyConfigured() public {
        uint256[] memory t = new uint256[](1);
        t[0] = CB;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetAlreadyConfigured.selector, address(token)));
        oracle.configureAssets(_arr(address(token)), t, t);
    }

    function test_configureAssets_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        uint256[] memory t = new uint256[](1);
        vm.prank(admin);
        vm.expectRevert(IPoppieEulerOracle.LengthMismatch.selector);
        oracle.configureAssets(a, t, t);
    }

    // --- keeperPushPrices ---

    function test_push_basic() public {
        _push(175.23e18);
        assertEq(oracle.getPrice(address(token)), 175.23e18);
    }

    function test_push_emitsPricesRefreshed() public {
        int256[] memory p = new int256[](1);
        p[0] = 175.23e18;
        vm.expectEmit(false, false, false, true);
        emit PricesRefreshed(_arr(address(token)));
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_notKeeper() public {
        int256[] memory p = new int256[](1);
        p[0] = 1e18;
        vm.prank(user);
        vm.expectRevert(IPoppieEulerOracle.OnlyKeeper.selector);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_invalidPrice() public {
        int256[] memory p = new int256[](1);
        p[0] = 0;
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.InvalidPrice.selector);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_negativePrice() public {
        int256[] memory p = new int256[](1);
        p[0] = -1;
        vm.prank(keeper);
        vm.expectRevert(IPoppieEulerOracle.InvalidPrice.selector);
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_notConfigured() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        int256[] memory p = new int256[](1);
        p[0] = 1e18;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotConfigured.selector, address(t2)));
        oracle.keeperPushPrices(_arr(address(t2)), p);
    }

    function test_push_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        int256[] memory p = new int256[](1);
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
        int256[] memory p = new int256[](1);
        p[0] = 160e18; // +60%, exceeds 50%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(token), 6000, CB));
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_cb_firstPriceNeverTriggers() public {
        _push(1_000_000e18); // arbitrary first price, no prior
        assertEq(oracle.getPrice(address(token)), 1_000_000e18);
    }

    function test_cb_zeroThresholdDisablesBreaker() public {
        // disable both the per-push CB and the cumulative cap
        vm.prank(admin);
        oracle.setAssetThresholds(address(token), 0, 0);
        _push(100e18);
        _push(100_000e18); // 1000x move allowed when both guards are 0
        assertEq(oracle.getPrice(address(token)), 100_000e18);
    }

    // --- getPrice staleness ---

    function test_getPrice_revert_uninitialized() public {
        vm.expectRevert(IPoppieEulerOracle.PriceNotInitialized.selector);
        oracle.getPrice(address(token));
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
        uint256[] memory th = new uint256[](1);
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
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetPaused.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_pauseAssets_admin() public {
        _push(100e18);
        vm.prank(admin);
        oracle.pauseAssets(_arr(address(token)));
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetPaused.selector, address(token)));
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
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetPaused.selector, address(token)));
        oracle.pauseAssets(_arr(address(token)));
    }

    function test_pause_keeperPushUnpauses() public {
        _push(100e18);
        // pause
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // admin sets recovery reference price
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 105e18);
        // still paused — getPrice reverts
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetPaused.selector, address(token)));
        oracle.getPrice(address(token));
        // keeper pushes an in-band price → auto-unpauses
        int256[] memory p = new int256[](1);
        p[0] = 106e18; // within 5000 bps of 105e18
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
        // now live
        assertEq(oracle.getPrice(address(token)), 106e18);
    }

    function test_pause_keeperPushRejectsOutOfBand() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // admin sets reference
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 100e18);
        // keeper tries to push way out of band
        int256[] memory p = new int256[](1);
        p[0] = 200e18; // +100%, way over 5000 bps threshold
        vm.prank(keeper);
        vm.expectRevert(); // CircuitBreakerTriggered
        oracle.keeperPushPrices(_arr(address(token)), p);
        // still paused
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetPaused.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_pause_adminSetPriceDoesNotUnpause() public {
        _push(100e18);
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // admin sets price — does NOT unpause
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 200e18);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetPaused.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_pause_fullRecoveryFlow() public {
        // normal price
        _push(100e18);
        // corporate action — keeper pauses
        vm.prank(keeper);
        oracle.pauseAssets(_arr(address(token)));
        // admin reviews and sets the post-event reference price
        vm.prank(admin);
        oracle.adminSetPrice(address(token), 150e18); // big move, bypasses guards
        // keeper's next run pushes a market price near the reference
        int256[] memory p = new int256[](1);
        p[0] = 152e18; // ~1.3% from reference, well within guards
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(token)), p);
        // asset is live again with the keeper's validated price
        assertEq(oracle.getPrice(address(token)), 152e18);
        assertFalse(oracle.getAssetConfig(address(token)).paused);
    }
}
