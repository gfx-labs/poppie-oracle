// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {OracleAdminGuard} from "../../src/peripheral/OracleAdminGuard.sol";

/// @dev Real oracle with OracleAdminGuard installed as admin. Assets A, B seeded at 100e18; C configured, unseeded.
abstract contract P3Base is Test {
    uint256 internal constant BAND = 500; // 5%
    uint256 internal constant DELAY = 1 days;
    uint256 internal constant LONG = 7 days;

    PoppieEulerOracle internal oracle;
    OracleAdminGuard internal g;

    address internal safe = makeAddr("safe");
    address internal second = makeAddr("secondSafe");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal backup = makeAddr("backupKeeper");
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        oracle = new PoppieEulerOracle(address(this), keeper, 3 days, 1 days);
        address[] memory as_ = new address[](3);
        (as_[0], as_[1], as_[2]) = (A, B, C);
        uint16[] memory cb = new uint16[](3);
        uint16[] memory cum = new uint16[](3);
        for (uint256 i; i < 3; ++i) (cb[i], cum[i]) = (1000, 2000);
        oracle.configureAssets(as_, cb, cum);
        oracle.adminSetPrice(A, 100e18);
        oracle.adminSetPrice(B, 100e18);

        g = new OracleAdminGuard(IPoppieEulerOracle(address(oracle)), BAND, DELAY, LONG, safe, second, guardian, backup);
        oracle.transferAdmin(address(g));
        g.acceptOracleAdmin();
    }

    // ── helpers ──
    function _submit(bytes memory data) internal {
        vm.prank(safe);
        g.submit(address(oracle), data);
    }

    function _exec(bytes memory data) internal {
        vm.prank(safe);
        g.execute(address(oracle), data);
    }

    function _id(bytes memory data) internal view returns (bytes32) {
        return keccak256(abi.encode(address(oracle), data));
    }

    function _queued(bytes memory data) internal view returns (bool) {
        return g.eta(_id(data)) != 0;
    }

    function _setPrice(address a, uint128 p) internal pure returns (bytes memory) {
        return abi.encodeCall(IPoppieEulerOracle.adminSetPrice, (a, p));
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _push(address a, uint128 p) internal {
        uint128[] memory ps = new uint128[](1);
        ps[0] = p;
        vm.prank(oracle.keeper());
        oracle.keeperPushPrices(_one(a), ps);
    }

    function _cfg(address a) internal view returns (IPoppieEulerOracle.AssetConfig memory) {
        return oracle.getAssetConfig(a);
    }
}
