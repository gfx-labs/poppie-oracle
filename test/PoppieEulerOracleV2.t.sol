// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracleV2} from "../src/PoppieEulerOracleV2.sol";
import {IPoppieEulerOracleV2} from "../src/interfaces/IPoppieEulerOracleV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PoppieEulerOracleV2Test is Test {
    // Mirror events for expectEmit assertions
    event PricesRefreshed(address[] assets);
    event AssetConfigured(address indexed asset);
    event CircuitBreakerThresholdSet(address indexed asset, uint256 threshold);
    event KeeperUpdated(address oldKeeper, address newKeeper);
    event AdminUpdated(address oldAdmin, address newAdmin);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event AdminPriceForced(address indexed asset, int256 price);
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge);

    PoppieEulerOracleV2 oracle;
    MockERC20 token;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address user = address(0xCC);

    uint256 constant MAX_AGE = 3600;
    uint256 constant CB = 5000; // 50% bps

    function setUp() public {
        token = new MockERC20("AAPLon", "AAPLon", 18);
        oracle = new PoppieEulerOracleV2(admin, keeper, MAX_AGE);

        address[] memory a = new address[](1);
        uint256[] memory t = new uint256[](1);
        a[0] = address(token);
        t[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(a, t);
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
        emit OracleDeployed(admin, keeper, MAX_AGE);
        new PoppieEulerOracleV2(admin, keeper, MAX_AGE);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert("PoppieEulerOracle: zero admin");
        new PoppieEulerOracleV2(address(0), keeper, MAX_AGE);
    }

    function test_constructor_revert_zeroKeeper() public {
        vm.expectRevert("PoppieEulerOracle: zero keeper");
        new PoppieEulerOracleV2(admin, address(0), MAX_AGE);
    }

    // --- configureAssets ---

    function test_configureAssets() public view {
        IPoppieEulerOracleV2.AssetConfig memory c = oracle.getAssetConfig(address(token));
        assertTrue(c.configured);
        assertEq(c.circuitBreakerThreshold, CB);
        assertEq(c.lastPrice, 0);
    }

    function test_configureAssets_emitsEvent() public {
        MockERC20 t2 = new MockERC20("Y", "Y", 18);
        uint256[] memory th = new uint256[](1);
        th[0] = CB;
        vm.expectEmit(true, false, false, true);
        emit AssetConfigured(address(t2));
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t2)), th);
    }

    function test_configureAssets_revert_notAdmin() public {
        address[] memory a = new address[](1);
        uint256[] memory t = new uint256[](1);
        vm.prank(user);
        vm.expectRevert("PoppieEulerOracle: only admin");
        oracle.configureAssets(a, t);
    }

    function test_configureAssets_revert_alreadyConfigured() public {
        uint256[] memory t = new uint256[](1);
        t[0] = CB;
        vm.prank(admin);
        vm.expectRevert("PoppieEulerOracle: asset already configured");
        oracle.configureAssets(_arr(address(token)), t);
    }

    function test_configureAssets_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        uint256[] memory t = new uint256[](1);
        vm.prank(admin);
        vm.expectRevert("PoppieEulerOracle: length mismatch");
        oracle.configureAssets(a, t);
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
        vm.expectRevert("PoppieEulerOracle: only keeper");
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_invalidPrice() public {
        int256[] memory p = new int256[](1);
        p[0] = 0;
        vm.prank(keeper);
        vm.expectRevert("PoppieEulerOracle: invalid price");
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_negativePrice() public {
        int256[] memory p = new int256[](1);
        p[0] = -1;
        vm.prank(keeper);
        vm.expectRevert("PoppieEulerOracle: invalid price");
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_push_revert_notConfigured() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        int256[] memory p = new int256[](1);
        p[0] = 1e18;
        vm.prank(keeper);
        vm.expectRevert("PoppieEulerOracle: asset not configured");
        oracle.keeperPushPrices(_arr(address(t2)), p);
    }

    function test_push_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        int256[] memory p = new int256[](1);
        vm.prank(keeper);
        vm.expectRevert("PoppieEulerOracle: length mismatch");
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
        vm.expectRevert("PoppieEulerOracle: circuit breaker triggered");
        oracle.keeperPushPrices(_arr(address(token)), p);
    }

    function test_cb_firstPriceNeverTriggers() public {
        _push(1_000_000e18); // arbitrary first price, no prior
        assertEq(oracle.getPrice(address(token)), 1_000_000e18);
    }

    function test_cb_zeroThresholdDisablesBreaker() public {
        vm.prank(admin);
        oracle.setCircuitBreakerThreshold(address(token), 0);
        _push(100e18);
        _push(100_000e18); // 1000x move allowed when threshold == 0
        assertEq(oracle.getPrice(address(token)), 100_000e18);
    }

    // --- getPrice staleness ---

    function test_getPrice_revert_uninitialized() public {
        vm.expectRevert("PoppieEulerOracle: price not initialized");
        oracle.getPrice(address(token));
    }

    function test_getPrice_revert_stale() public {
        _push(100e18);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert("PoppieEulerOracle: stale price");
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
        vm.expectRevert("PoppieEulerOracle: only admin");
        oracle.adminSetPrice(address(token), 1e18);
    }

    function test_adminSetPrice_revert_invalidPrice() public {
        vm.prank(admin);
        vm.expectRevert("PoppieEulerOracle: invalid price");
        oracle.adminSetPrice(address(token), 0);
    }

    function test_adminSetPrice_revert_notConfigured() public {
        MockERC20 t2 = new MockERC20("X", "X", 18);
        vm.prank(admin);
        vm.expectRevert("PoppieEulerOracle: asset not configured");
        oracle.adminSetPrice(address(t2), 1e18);
    }

    function test_adminSetPrices_batch() public {
        int256[] memory p = new int256[](1);
        p[0] = 50e18;
        vm.prank(admin);
        oracle.adminSetPrices(_arr(address(token)), p);
        assertEq(oracle.getPrice(address(token)), 50e18);
    }

    function test_adminSetPrices_revert_lengthMismatch() public {
        address[] memory a = new address[](2);
        int256[] memory p = new int256[](1);
        vm.prank(admin);
        vm.expectRevert("PoppieEulerOracle: length mismatch");
        oracle.adminSetPrices(a, p);
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
        vm.expectRevert("PoppieEulerOracle: zero keeper");
        oracle.setKeeper(address(0));
    }

    function test_setAdmin() public {
        vm.expectEmit(false, false, false, true);
        emit AdminUpdated(admin, address(0xEE));
        vm.prank(admin);
        oracle.setAdmin(address(0xEE));
        assertEq(oracle.admin(), address(0xEE));
    }

    function test_setAdmin_revert_zero() public {
        vm.prank(admin);
        vm.expectRevert("PoppieEulerOracle: zero admin");
        oracle.setAdmin(address(0));
    }

    function test_setMaxPriceAge() public {
        vm.expectEmit(false, false, false, true);
        emit MaxPriceAgeUpdated(MAX_AGE, 7200);
        vm.prank(admin);
        oracle.setMaxPriceAge(7200);
        assertEq(oracle.maxPriceAge(), 7200);
    }

    function test_setCircuitBreakerThreshold() public {
        vm.expectEmit(true, false, false, true);
        emit CircuitBreakerThresholdSet(address(token), 1000);
        vm.prank(admin);
        oracle.setCircuitBreakerThreshold(address(token), 1000);
        assertEq(oracle.getAssetConfig(address(token)).circuitBreakerThreshold, 1000);
    }
}
