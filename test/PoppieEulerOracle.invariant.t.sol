// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Bounded actor driving keeper/admin flows for the oracle+adapter.
contract OracleHandler is Test {
    PoppieEulerOracle public oracle;
    PoppieEulerAdapter public adapter;
    address public token;
    address public keeper;
    address public admin;
    address public adapterAdmin;

    constructor(
        PoppieEulerOracle _oracle,
        PoppieEulerAdapter _adapter,
        address _token,
        address _keeper,
        address _admin,
        address _adapterAdmin
    ) {
        oracle = _oracle;
        adapter = _adapter;
        token = _token;
        keeper = _keeper;
        admin = _admin;
        adapterAdmin = _adapterAdmin;
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    /// Keeper pushes within the circuit-breaker band (so calls succeed).
    function pushPrice(uint256 seed) public {
        uint128 last = oracle.getAssetConfig(token).lastPrice;
        uint256 base = last > 0 ? uint256(last) : 100e18;
        uint256 next = bound(seed, (base * 60) / 100, (base * 140) / 100);
        if (next == 0) next = 1;
        uint128[] memory p = new uint128[](1);
        p[0] = uint128(next);
        vm.prank(keeper);
        try oracle.keeperPushPrices(_arr(token), p) {} catch {}
    }

    /// Admin force-push (recovery) — any positive price.
    function adminForce(uint256 seed) public {
        uint256 next = bound(seed, 1, 1e30);
        vm.prank(admin);
        try oracle.adminSetPrice(token, uint128(next)) {} catch {}
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
    }

    function setMaxAge(uint256 secs) public {
        vm.prank(admin);
        try oracle.setMaxPriceAge(bound(secs, 1, 1 days)) {} catch {}
    }
}

contract PoppieEulerOracleInvariantTest is StdInvariant, Test {
    PoppieEulerOracle oracle;
    PoppieEulerAdapter adapter;
    MockERC20 token;
    OracleHandler handler;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address aAdmin = address(0xA1);
    address constant UNIT = address(840);
    uint16 constant CB = 5000;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        oracle = new PoppieEulerOracle(admin, keeper, 3600, 86400);
        adapter = new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 18);

        uint16[] memory t = new uint16[](1);
        address[] memory a = new address[](1);
        a[0] = address(token);
        t[0] = CB;
        vm.prank(admin);
        oracle.configureAssets(a, t, t);
        uint8 dec = token.decimals();
        vm.prank(aAdmin);
        adapter.registerBase(address(token), dec);

        uint128[] memory p = new uint128[](1);
        p[0] = 100e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(a, p);

        handler = new OracleHandler(oracle, adapter, address(token), keeper, admin, aAdmin);
        targetContract(address(handler));
    }

    /// Stored price is always strictly positive once seeded.
    function invariant_priceAlwaysPositive() public view {
        assertGt(oracle.getAssetConfig(address(token)).lastPrice, 0);
    }

    /// lastPriceTimestamp never exceeds current block time.
    function invariant_timestampSane() public view {
        assertLe(oracle.getAssetConfig(address(token)).lastPriceTimestamp, block.timestamp);
    }

    /// Asset stays "configured" across all keeper/admin ops.
    function invariant_assetStaysConfigured() public view {
        assertTrue(oracle.getAssetConfig(address(token)).configured);
    }
}
