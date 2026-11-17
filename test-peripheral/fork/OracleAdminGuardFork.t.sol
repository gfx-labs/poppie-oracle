// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkUtil} from "../lib/ForkUtil.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {OracleAdminGuard} from "../../src/peripheral/OracleAdminGuard.sol";

/// @dev Audited oracle + adapter deployed on an Arbitrum fork, pricing a real xStock, with P3 as admin.
///      "Safe-shaped": every Safe action is a call from the Safe address; a MultiSend is modelled as
///      several such calls in one block.
contract OracleAdminGuardForkTest is ForkUtil {
    address internal constant XSTOCK = 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a; // Backed xStock (see eval/fork)
    address internal constant USD = address(840);

    PoppieEulerOracle internal oracle;
    PoppieEulerAdapter internal adapter;
    OracleAdminGuard internal g;
    address internal safe = makeAddr("oracleSafe");
    address internal second = makeAddr("secondSafe");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        if (!_forkArbitrum()) return;
        oracle = new PoppieEulerOracle(safe, keeper, 3 days, 1 days);
        adapter = new PoppieEulerAdapter(address(oracle), safe, USD, 18);
        g = new OracleAdminGuard(IPoppieEulerOracle(address(oracle)), 500, 1 days, 7 days, safe, second, guardian, makeAddr("bk"));

        address[] memory a = new address[](1);
        a[0] = XSTOCK;
        uint16[] memory cb = new uint16[](1);
        cb[0] = 1000;
        vm.startPrank(safe);
        oracle.configureAssets(a, cb, cb);
        adapter.registerBase(XSTOCK, 18); // cross-checks real decimals()
        oracle.transferAdmin(address(g));
        vm.stopPrank();
        g.acceptOracleAdmin();
    }

    function _submit(bytes memory d) internal {
        vm.prank(safe);
        g.submit(address(oracle), d);
    }

    function test_fork_seedPriceAndWalkBlocked() public {
        assertEq(oracle.admin(), address(g));
        _submit(abi.encodeCall(IPoppieEulerOracle.adminSetPrice, (XSTOCK, 250e18))); // seed
        assertEq(adapter.getQuote(1e18, XSTOCK, USD), 250e18);

        // Safe "MultiSend": three +4% steps in one block. Only the first lands instantly.
        _submit(abi.encodeCall(IPoppieEulerOracle.adminSetPrice, (XSTOCK, 260e18)));
        bytes memory step2 = abi.encodeCall(IPoppieEulerOracle.adminSetPrice, (XSTOCK, 270e18));
        _submit(step2);
        assertEq(adapter.getQuote(1e18, XSTOCK, USD), 260e18);
        assertGt(g.eta(keccak256(abi.encode(address(oracle), step2))), 0);

        // guardian pause, then in-band recovery from the recorded pre-pause price
        address[] memory a = new address[](1);
        a[0] = XSTOCK;
        vm.prank(guardian);
        g.pauseAssets(a);
        vm.expectRevert();
        adapter.getQuote(1e18, XSTOCK, USD);
        vm.warp(block.timestamp + 1 days);
        _submit(abi.encodeCall(IPoppieEulerOracle.adminSetPrice, (XSTOCK, 255e18)));
        uint128[] memory p = new uint128[](1);
        p[0] = 256e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(a, p);
        assertEq(adapter.getQuote(1e18, XSTOCK, USD), 256e18);
    }
}
