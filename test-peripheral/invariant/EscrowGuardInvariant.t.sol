// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {P2Base} from "../lib/P2Base.sol";
import {MockVault, MockEVC, MockSanctions} from "../lib/Mocks.sol";
import {EscrowGuard} from "../../src/peripheral/EscrowGuard.sol";

contract P2Handler is Test {
    EscrowGuard internal g;
    MockEVC internal evc;
    MockSanctions internal sanc;
    MockVault[2] internal escrows;
    address[2] internal groups;
    address[4] internal users;
    address internal liquidator = address(0x11D);

    uint256 public violations;
    uint256 public seizures;
    uint256[] public days_;
    mapping(address => uint40) public lastPaused;
    address[] public deniedList;

    constructor(EscrowGuard g_, MockEVC evc_, MockSanctions s_, MockVault e1, MockVault e2, address G, address H) {
        (g, evc, sanc) = (g_, evc_, s_);
        escrows = [e1, e2];
        groups = [G, H];
        for (uint256 i; i < 4; ++i) {
            users[i] = address(uint160(0x2000 + i));
            vm.startPrank(users[i]);
            e1.deposit(1e18, users[i]);
            e2.deposit(1e18, users[i]);
            vm.stopPrank();
        }
    }

    function addWindow(uint256 grp, uint256 startOff, uint256 len) external {
        uint256 s = block.timestamp + bound(startOff, 0, 2 days);
        uint256 e = s + bound(len, 1, 6 hours);
        vm.prank(g.scheduler());
        try g.addWindow(groups[grp % 2], uint40(s), uint40(e)) {
            days_.push(s / 1 days);
        } catch {}
    }

    function pause(uint256 i, uint256 d) external {
        address e = address(escrows[i % 2]);
        vm.prank(g.guardian());
        try g.pauseDeposits(e, bound(d, 0, 10 days)) {} catch {}
        if (g.pausedUntil(e) < lastPaused[e]) violations++;
        lastPaused[e] = g.pausedUntil(e);
    }

    function deny(uint256 u, bool sanction) external {
        address a = users[u % 4];
        if (sanction) {
            sanc.set(a, true);
        } else {
            address[] memory l = new address[](1);
            l[0] = a;
            vm.prank(g.denylister());
            g.deny(l);
            deniedList.push(a);
        }
        for (uint256 i; i < deniedList.length; ++i) if (!g.denied(deniedList[i])) violations++;
    }

    function freeze(uint256 u) external {
        address[] memory l = new address[](1);
        l[0] = users[u % 4];
        vm.prank(g.denylister());
        g.freeze(l);
    }

    function deposit(uint256 i, uint256 u, uint256 x) external {
        vm.prank(users[u % 4]);
        try escrows[i % 2].deposit(bound(x, 0, 1e18), users[u % 4]) {} catch {}
    }

    function withdraw(uint256 i, uint256 u, uint256 x) external {
        MockVault e = escrows[i % 2];
        address a = users[u % 4];
        vm.prank(a);
        try e.withdraw(x % (e.balanceOf(a) + 1), a, a) {} catch {}
    }

    /// @dev Liquidation seizure: the EVC transfers the violator's shares during controlCollateral.
    function seize(uint256 i, uint256 u, uint8 how) external {
        MockVault e = escrows[i % 2];
        address v = users[u % 4];
        uint256 bal = e.balanceOf(v);
        evc.setControlCollateral(true);
        vm.prank(v);
        if (how % 3 == 0) {
            try e.transfer(liquidator, bal / 2) { seizures++; } catch { violations++; }
        } else if (how % 3 == 1) {
            try e.transferFrom(v, liquidator, bal / 2) { seizures++; } catch { violations++; }
        } else {
            try e.transferFromMax(v, liquidator) { seizures++; } catch { violations++; }
        }
        evc.setControlCollateral(false);
    }

    function hotKeyOverreach(uint256 who) external {
        address k = who % 3 == 0 ? g.guardian() : who % 3 == 1 ? g.scheduler() : g.denylister();
        vm.startPrank(k);
        try g.unpause(address(escrows[0])) { violations++; } catch {}
        try g.clearWindows(groups[0], block.timestamp / 1 days) { violations++; } catch {}
        try g.removeDenied(users[0]) { violations++; } catch {}
        try g.setEscrow(address(escrows[0]), address(0)) { violations++; } catch {}
        try g.unfreeze(users[0]) { violations++; } catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 12 hours));
    }

    function daysLength() external view returns (uint256) {
        return days_.length;
    }

    function groupAt(uint256 i) external view returns (address) {
        return groups[i];
    }
}

contract EscrowGuardInvariantTest is P2Base {
    P2Handler internal h;

    function setUp() public override {
        super.setUp();
        e1.setHookConfig(address(g), ALL_OPS); // worst case: transfers hooked too
        e2.setHookConfig(address(g), ALL_OPS);
        h = new P2Handler(g, evc, sanc, e1, e2, G, H);
        targetContract(address(h));
    }

    function invariant_seizureNeverReverts_hotKeysTightenOnly() public view {
        assertEq(h.violations(), 0);
    }

    function invariant_windowsBounded() public view {
        for (uint256 i; i < h.daysLength(); ++i) {
            uint256 day = h.days_(i);
            for (uint256 k; k < 2; ++k) {
                EscrowGuard.Window[] memory w = g.windowsOf(h.groupAt(k), day);
                assertLe(w.length, MAX_PER_DAY);
                for (uint256 j; j < w.length; ++j) {
                    assertLe(w[j].end - w[j].start, MAX_LEN);
                    assertEq(w[j].start / 1 days, day);
                    assertEq((w[j].end - 1) / 1 days, day);
                }
            }
        }
    }

    function invariant_noBalance() public view {
        assertEq(address(g).balance, 0);
    }

    // ── explicit: seizure passes with every block active ──
    function test_seizure_allBlocksActive() public {
        _addWindow(G, block.timestamp, block.timestamp + 1 hours);
        vm.prank(guardian);
        g.pauseDeposits(address(e1), 7 days);
        vm.prank(denylister);
        g.deny(_arr(user));
        vm.prank(denylister);
        g.freeze(_arr(user));
        sanc.set(user, true);

        address liq = makeAddr("liq");
        evc.setControlCollateral(true);
        vm.startPrank(user);
        e1.transfer(liq, 10);
        e1.transferFrom(user, liq, 10);
        e1.transferFromMax(user, liq);
        vm.stopPrank();
        assertEq(e1.balanceOf(liq), 100);
        // A24 (accepted): the liquidator cannot redeem the seized shares inside the window
        evc.setControlCollateral(false);
        vm.prank(liq);
        vm.expectRevert(EscrowGuard.InWindow.selector);
        e1.redeem(10, liq, liq);
    }

    function test_handlerActionsLand() public {
        h.freeze(0);
        h.seize(0, 0, 0);
        h.seize(1, 1, 2);
        h.addWindow(0, 1 hours, 1 hours);
        assertEq(h.seizures(), 2);
        assertEq(h.daysLength(), 1);
        assertEq(h.violations(), 0);
    }
}
