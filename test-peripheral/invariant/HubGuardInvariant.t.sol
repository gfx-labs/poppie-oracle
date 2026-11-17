// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {P1Base} from "../lib/P1Base.sol";
import {MockVault, MockSanctions} from "../lib/Mocks.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";

contract P1Handler is Test {
    MockVault internal hub;
    HubGuard internal g;
    MockSanctions internal sanc;
    address internal guardian;
    address internal denylister;
    address internal feeRcv;
    uint256 internal limit;
    uint256 internal window;
    uint256 internal feeBps;
    address[4] internal users;

    uint256 public violations;
    uint256 public borrowBatches;
    uint256 public ghostStart;
    uint256 public ghostUsed;
    uint40 public lastPausedUntil;
    address[] public deniedList;

    constructor(MockVault hub_, HubGuard g_, MockSanctions s_, address feeRcv_, uint256 limit_, uint256 window_, uint256 fee_) {
        (hub, g, sanc, feeRcv, limit, window, feeBps) = (hub_, g_, s_, feeRcv_, limit_, window_, fee_);
        guardian = g.guardian();
        denylister = g.denylister();
        // forge-lint: disable-next-line(unsafe-typecast) small constant address
        for (uint256 i; i < 4; ++i) users[i] = address(uint160(0x1000 + i));
    }

    function borrowBatch(uint256 u, uint256 x, uint256 feeAdj, bool toFeeRcv) external {
        address who = users[u % 4];
        x = bound(x, 1, limit);
        uint256 owed = toFeeRcv ? 0 : (x * feeBps + 9_999) / 10_000;
        uint256 fee = owed == 0 ? 0 : bound(feeAdj, owed - (owed > 1 ? 1 : 0), owed + 1); // around the boundary
        bytes[] memory c = new bytes[](fee == 0 ? 1 : 2);
        c[0] = abi.encodeCall(MockVault.borrow, (x, toFeeRcv ? feeRcv : who));
        if (fee != 0) c[1] = abi.encodeCall(MockVault.borrow, (fee, feeRcv));
        uint256 tb0 = hub.totalBorrows();
        vm.prank(who);
        try hub.batch(c) {
            borrowBatches++;
            uint256 paid = toFeeRcv ? x + fee : fee;
            if (paid < owed) violations++;
            if (block.timestamp >= ghostStart + window) (ghostStart, ghostUsed) = (block.timestamp, 0);
            ghostUsed += hub.totalBorrows() - tb0;
            if (ghostUsed > limit) violations++;
        } catch {}
    }

    function repay(uint256 u, uint256 x) external {
        address who = users[u % 4];
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(MockVault.repay, (x % (hub.debtOf(who) + 1), who));
        vm.prank(who);
        try hub.batch(c) {} catch { violations++; }
    }

    function liquidate(uint256 u, uint256 l, uint256 x) external {
        address v = users[u % 4];
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(MockVault.liquidate, (v, address(0), x % (hub.debtOf(v) + 1), 0));
        vm.prank(users[l % 4]);
        try hub.batch(c) {} catch { violations++; }
    }

    function deposit(uint256 u, uint256 x) external {
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(MockVault.deposit, (x % 1e30, users[u % 4]));
        vm.prank(users[u % 4]);
        try hub.batch(c) {} catch {}
    }

    function pause(uint256 d) external {
        vm.prank(guardian);
        try g.pause(address(hub), d % 10 days) {} catch {}
        (,,,, uint40 until,,,,) = g.cfg(address(hub));
        if (until < lastPausedUntil) violations++;
        lastPausedUntil = until;
    }

    function deny(uint256 u, bool sanction) external {
        address a = users[u % 4];
        if (sanction) {
            sanc.set(a, true);
        } else {
            address[] memory l = new address[](1);
            l[0] = a;
            vm.prank(denylister);
            g.deny(l);
            deniedList.push(a);
        }
        for (uint256 i; i < deniedList.length; ++i) if (!g.denied(deniedList[i])) violations++;
    }

    /// @dev Hot keys trying owner functions must always fail.
    function hotKeyOverreach(bool asGuardian) external {
        vm.startPrank(asGuardian ? guardian : denylister);
        try g.unpause(address(hub)) { violations++; } catch {}
        try g.removeDenied(users[0]) { violations++; } catch {}
        try g.setHub(address(hub), type(uint128).max, 0, 0, address(0), 1) { violations++; } catch {}
        try g.setGuardian(address(this)) { violations++; } catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 hours));
    }
}

contract HubGuardInvariantTest is P1Base {
    P1Handler internal h;

    function setUp() public override {
        super.setUp();
        hub.setHookConfig(address(g), ALL_OPS); // worst-case misconfiguration
        h = new P1Handler(hub, g, sanc, feeRcv, LIMIT, WINDOW, FEE);
        targetContract(address(h));
    }

    function invariant_noViolations() public view {
        assertEq(h.violations(), 0);
    }

    function invariant_usedWithinLimit() public view {
        (,,,,,,,, uint256 used) = g.cfg(address(hub));
        assertLe(used, LIMIT);
    }

    function invariant_batchAlwaysCleared() public view {
        (bool borrowed,,,) = g.batch(address(hub));
        assertFalse(borrowed);
    }

    function invariant_noBalance() public view {
        assertEq(address(g).balance, 0);
    }

    function test_handlerActionsLand() public {
        h.borrowBatch(0, 100e6, 0, true);
        h.borrowBatch(1, 100e6, type(uint256).max, false);
        h.repay(0, 50e6);
        h.liquidate(1, 2, 10e6);
        assertEq(h.borrowBatches(), 2);
        assertEq(h.violations(), 0);
    }

    // ── fuzz: a status check with no borrow never reverts, whatever the state ──
    function testFuzz_statusCheckNoBorrow_neverReverts(
        uint128 limit,
        uint32 window,
        uint16 fee,
        bool flash,
        uint256 pauseFor,
        uint256 tb,
        bool denyAll,
        bytes calldata junk
    ) public {
        vm.prank(ops);
        g.setHub(address(hub), limit, window, uint16(bound(fee, 0, 100)), feeRcv, flash ? 1 : 0);
        vm.prank(guardian);
        g.pause(address(hub), bound(pauseFor, 0, 7 days));
        hub.setTotalBorrows(tb);
        hub.setHookConfig(address(g), ALL_OPS);
        if (denyAll) {
            vm.prank(denylister);
            g.deny(_arr(address(this)));
            sanc.set(address(this), true);
        }
        hub.statusCheck();
        // direct call from any address with arbitrary trailing bytes
        vm.prank(address(uint160(uint256(keccak256(junk)))));
        (bool ok,) = address(g).call(abi.encodePacked(abi.encodeWithSignature("checkVaultStatus()"), junk));
        assertTrue(ok);
    }
}
