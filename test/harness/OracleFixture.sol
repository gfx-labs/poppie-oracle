// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/oracle/PoppieEulerAdapter.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {MS_OPS, K_PRICE, K_CONFIRM} from "../../src/access/Roles.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Oracle + adapter deployed locally with the three roles granted. Every call goes through the interface
/// types, so the tests also pin the ABI of `IPoppieEulerOracle` and `IPoppieEulerAdapter`.
abstract contract OracleFixture is Test {
    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant BPS = 10_000;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");
    address internal ops = makeAddr("ops");

    PoppieEulerOracle internal impl;
    IPoppieEulerOracle internal oracle;
    IPoppieEulerAdapter internal adapter;

    /// @dev 18 decimals, blue chip.
    MockERC20 internal tokenA;
    /// @dev 6 decimals, M1.
    MockERC20 internal tokenB;
    /// @dev 8 decimals, M3.
    MockERC20 internal tokenC;

    function setUp() public virtual {
        vm.warp(T0);
        impl = new PoppieEulerOracle(admin);
        oracle = IPoppieEulerOracle(address(impl));
        adapter = IPoppieEulerAdapter(address(new PoppieEulerAdapter(oracle)));

        vm.startPrank(admin);
        impl.grantRole(K_PRICE, keeper);
        impl.grantRole(K_CONFIRM, confirmer);
        impl.grantRole(MS_OPS, ops);
        vm.stopPrank();

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 6);
        tokenC = new MockERC20("C", "C", 8);
        _list(address(tokenA), IPoppieEulerOracle.PriceClass.BlueChip);
        _list(address(tokenB), IPoppieEulerOracle.PriceClass.M1);
        _list(address(tokenC), IPoppieEulerOracle.PriceClass.M3);
    }

    // -- Actions ---------------------------------------------------------------------------------

    function _list(address token, IPoppieEulerOracle.PriceClass c) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](1);
        cs[0] = c;
        vm.prank(ops);
        oracle.listAssets(t, cs);
    }

    function _push(address asset, uint128 price) internal {
        address[] memory a = new address[](1);
        a[0] = asset;
        uint128[] memory p = new uint128[](1);
        p[0] = price;
        vm.prank(keeper);
        oracle.keeperPushPrices(a, p);
    }

    function _pushPacked(address asset, uint96 price) internal {
        bytes memory data = PackedPrices.encode(oracle.assetId(asset), price);
        vm.prank(keeper);
        oracle.keeperPushPacked(data);
    }

    function _confirm(address asset, uint128 price) internal {
        vm.prank(confirmer);
        oracle.confirm(asset, price);
    }

    function _pause(address asset) internal {
        address[] memory a = new address[](1);
        a[0] = asset;
        vm.prank(keeper);
        oracle.pauseAssets(a);
    }

    function _unpause(address asset) internal {
        address[] memory a = new address[](1);
        a[0] = asset;
        vm.prank(ops);
        oracle.unpauseAssets(a);
    }

    /// @dev First price for `asset`: push, then confirm. Leaves it Live at `price`.
    function _goLive(address asset, uint128 price) internal {
        _push(asset, price);
        _confirm(asset, price);
    }

    function _price(uint256 whole) internal pure returns (uint128) {
        return uint128(whole * 1e18);
    }

    // -- Views -----------------------------------------------------------------------------------

    function _state(address asset) internal view returns (IPoppieEulerOracle.PriceState) {
        return oracle.state(asset);
    }

    function _data(address asset) internal view returns (IPoppieEulerOracle.AssetData memory) {
        return oracle.getAssetData(asset);
    }
}
