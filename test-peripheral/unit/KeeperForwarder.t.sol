// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {P3Base} from "../lib/P3Base.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {KeeperForwarder} from "../../src/peripheral/KeeperForwarder.sol";

abstract contract P4Base is Test {
    PoppieEulerOracle internal oracle;
    KeeperForwarder internal f;
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal k1 = makeAddr("k1");
    address internal k2 = makeAddr("k2");
    address[] internal assets;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        oracle = new PoppieEulerOracle(address(this), address(1), 3 days, 1 days);
        f = new KeeperForwarder(IPoppieEulerOracle(address(oracle)), admin, guardian, 2, 1 days);
        oracle.setKeeper(address(f));
        uint16[] memory cb = new uint16[](5);
        for (uint256 i; i < 5; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) small constant address
            assets.push(address(uint160(0xA000 + i)));
            cb[i] = 1000;
        }
        oracle.configureAssets(assets, cb, cb);
        for (uint256 i; i < 5; ++i) oracle.adminSetPrice(assets[i], 100e18);
        vm.startPrank(admin);
        f.addKeeper(k1);
        f.addKeeper(k2);
        vm.stopPrank();
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _p(uint128 p) internal pure returns (uint128[] memory r) {
        r = new uint128[](1);
        r[0] = p;
    }
}

contract KeeperForwarderUnitTest is P4Base {
    function test_severalKeysPushIndependently() public {
        vm.prank(k1);
        f.push(_one(assets[0]), _p(101e18));
        vm.prank(k2);
        f.push(_one(assets[1]), _p(99e18));
        assertEq(oracle.getAssetConfig(assets[0]).lastPrice, 101e18);
        assertEq(oracle.getAssetConfig(assets[1]).lastPrice, 99e18);
    }

    function test_nonKeeper_reverts() public {
        vm.expectRevert(KeeperForwarder.NotKeeper.selector);
        f.push(_one(assets[0]), _p(101e18));
        vm.expectRevert(KeeperForwarder.NotKeeper.selector);
        f.pauseAssets(_one(assets[0]));
    }

    function test_revokedKey_reverts() public {
        vm.prank(guardian);
        f.removeKeeper(k1);
        vm.prank(k1);
        vm.expectRevert(KeeperForwarder.NotKeeper.selector);
        f.push(_one(assets[0]), _p(101e18));
        vm.prank(k2);
        f.push(_one(assets[0]), _p(101e18));
    }

    function test_breakerPassthrough() public {
        vm.prank(k1);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, assets[0], 1100, 1000)
        );
        f.push(_one(assets[0]), _p(111e18));
    }

    function test_budget_boundary_andReset() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (assets[0], assets[1]);
        vm.prank(k1);
        f.pauseAssets(two); // used 2/2
        vm.prank(k2);
        vm.expectRevert(KeeperForwarder.BudgetExceeded.selector);
        f.pauseAssets(_one(assets[2])); // global across keys
        vm.warp(block.timestamp + 1 days - 1);
        vm.prank(k1);
        vm.expectRevert(KeeperForwarder.BudgetExceeded.selector);
        f.pauseAssets(_one(assets[2]));
        vm.warp(block.timestamp + 1);
        vm.prank(k1);
        f.pauseAssets(_one(assets[2]));
        assertTrue(oracle.getAssetConfig(assets[2]).paused);
        assertEq(f.used(), 1);
    }

    function test_budget_batchOverN_reverts() public {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (assets[0], assets[1], assets[2]);
        vm.prank(k1);
        vm.expectRevert(KeeperForwarder.BudgetExceeded.selector);
        f.pauseAssets(three);
    }

    function test_guardianOnlyRemoves() public {
        vm.startPrank(guardian);
        vm.expectRevert(KeeperForwarder.Unauthorized.selector);
        f.addKeeper(guardian);
        vm.expectRevert(KeeperForwarder.Unauthorized.selector);
        f.setBudget(100, 1);
        vm.expectRevert(KeeperForwarder.Unauthorized.selector);
        f.setGuardian(address(0));
        vm.expectRevert(KeeperForwarder.Unauthorized.selector);
        f.setAdmin(guardian);
        vm.stopPrank();
    }

    function test_adminFunctions() public {
        vm.startPrank(admin);
        f.setBudget(5, 2 days);
        f.removeKeeper(k2);
        f.setGuardian(k2);
        f.setAdmin(k1);
        vm.stopPrank();
        assertEq(f.n(), 5);
        assertEq(f.window(), 2 days);
        assertFalse(f.isKeeper(k2));
        assertEq(f.guardian(), k2);
        assertEq(f.admin(), k1);
    }
}

contract KeeperForwarderFuzzTest is P4Base {
    /// @dev Random pause attempts (random keys, sizes, time gaps) never exceed n per window.
    function testFuzz_pausesBoundedPerWindow(uint8[24] memory sizes, uint32[24] memory gaps, bool[24] memory key) public {
        // fresh asset per slot so the oracle never rejects for "already paused"
        uint256 next;
        address[] memory pool = new address[](48);
        uint16[] memory cb = new uint16[](48);
        for (uint256 i; i < 48; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) small constant address
            pool[i] = address(uint160(0xB000 + i));
            cb[i] = 1000;
        }
        oracle.configureAssets(pool, cb, cb);

        uint256 wStart;
        uint256 wCount;
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + (gaps[i] % 2 days));
            uint256 sz = 1 + sizes[i] % 3;
            if (next + sz > 48) break;
            address[] memory batch = new address[](sz);
            for (uint256 j; j < sz; ++j) batch[j] = pool[next + j];
            vm.prank(key[i] ? k1 : k2);
            try f.pauseAssets(batch) {
                next += sz;
                if (block.timestamp >= wStart + 1 days) (wStart, wCount) = (block.timestamp, 0);
                wCount += sz;
                assertLe(wCount, 2, "more than n pauses in a window");
            } catch {}
        }
    }
}

/// @dev P3 is P4's admin; the oracle admin is P3.
contract KeeperForwarderP3Test is P3Base {
    KeeperForwarder internal f;

    function setUp() public override {
        super.setUp();
        f = new KeeperForwarder(IPoppieEulerOracle(address(oracle)), address(g), guardian, 2, 1 days);
    }

    function test_installForwarder_isDelayed() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setKeeper, (address(f)));
        _submit(d);
        assertEq(oracle.keeper(), keeper);
        vm.warp(block.timestamp + DELAY);
        _exec(d);
        assertEq(oracle.keeper(), address(f));
    }

    function test_addKeeper_throughP3_isDelayed() public {
        address k = makeAddr("k");
        bytes memory d = abi.encodeCall(KeeperForwarder.addKeeper, (k));
        vm.prank(safe);
        g.submit(address(f), d);
        assertFalse(f.isKeeper(k));
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        g.execute(address(f), d);
        assertTrue(f.isKeeper(k));
    }

    function test_exit_setKeeperBackup_isInstant() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.setKeeper, (address(f)));
        _submit(d);
        vm.warp(block.timestamp + DELAY);
        _exec(d);
        _submit(abi.encodeCall(IPoppieEulerOracle.setKeeper, (backup)));
        assertEq(oracle.keeper(), backup);
        _push(A, 101e18); // backup keeper pushes directly
        assertEq(_cfg(A).lastPrice, 101e18);
    }

    function test_p4GuardianRemovesKey_instantly() public {
        address k = makeAddr("k");
        bytes memory d = abi.encodeCall(KeeperForwarder.addKeeper, (k));
        vm.prank(safe);
        g.submit(address(f), d);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        g.execute(address(f), d);
        vm.prank(guardian);
        f.removeKeeper(k);
        assertFalse(f.isKeeper(k));
    }
}
