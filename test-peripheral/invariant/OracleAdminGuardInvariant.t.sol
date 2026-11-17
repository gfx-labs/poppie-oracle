// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {P3Base} from "../lib/P3Base.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {OracleAdminGuard} from "../../src/peripheral/OracleAdminGuard.sol";

contract P3Handler is Test {
    struct Snap {
        uint16[3] cb;
        uint16[3] cum;
        uint256[3] effAge; // 0 = disabled
        uint256 anchorWindow;
        address keeper;
        address pendingAdmin;
    }

    PoppieEulerOracle internal oracle;
    OracleAdminGuard internal g;
    address internal safe;
    address internal second;
    address internal guardian;
    address internal backup;
    address[3] internal assets;

    bytes[] internal queuedData;
    mapping(bytes32 => uint256) public queuedAt; // eta seen at queue time
    mapping(bytes32 => uint256) public queuedTs; // timestamp of queueing
    uint256 public violations;
    uint256 public calls;

    constructor(PoppieEulerOracle o, OracleAdminGuard g_, address[3] memory as_) {
        oracle = o;
        g = g_;
        safe = g.safe();
        second = g.secondSafe();
        guardian = g.guardian();
        backup = g.backupKeeper();
        assets = as_;
    }

    function _snap() internal view returns (Snap memory s) {
        uint256 gl = oracle.maxPriceAge();
        for (uint256 i; i < 3; ++i) {
            IPoppieEulerOracle.AssetConfig memory c = oracle.getAssetConfig(assets[i]);
            s.cb[i] = c.circuitBreakerThreshold;
            s.cum[i] = c.cumulativeDeviationCap;
            s.effAge[i] = c.maxPriceAge != 0 ? c.maxPriceAge : gl;
        }
        s.anchorWindow = oracle.anchorWindow();
        s.keeper = oracle.keeper();
        s.pendingAdmin = oracle.pendingAdmin();
    }

    function _looser(uint256 a, uint256 b) internal pure returns (bool) {
        // b looser than a, where 0 means disabled
        return a != b && (b == 0 || (a != 0 && b > a));
    }

    function _loosened(Snap memory a, Snap memory b) internal view returns (bool) {
        for (uint256 i; i < 3; ++i) {
            if (_looser(a.cb[i], b.cb[i]) || b.cum[i] > a.cum[i] || _looser(a.effAge[i], b.effAge[i])) return true;
        }
        return a.anchorWindow != b.anchorWindow || (a.keeper != b.keeper && b.keeper != backup)
            || a.pendingAdmin != b.pendingAdmin;
    }

    function _candidate(uint256 k, uint256 v) internal view returns (bytes memory) {
        address a = assets[v % 3];
        uint256 kind = k % 8;
        if (kind == 0) return abi.encodeCall(IPoppieEulerOracle.adminSetPrice, (a, uint128(bound(v, 1, 300e18))));
        if (kind == 1) {
            return abi.encodeCall(
                IPoppieEulerOracle.setAssetThresholds, (a, SafeCast.toUint16(v % 3000), SafeCast.toUint16(1 + (v >> 8) % 3000))
            );
        }
        if (kind == 2) return abi.encodeCall(IPoppieEulerOracle.setMaxPriceAge, ((v % 4) * 1 days));
        if (kind == 3) return abi.encodeCall(IPoppieEulerOracle.setAssetMaxPriceAge, (a, uint40((v % 5) * 1 days)));
        if (kind == 4) return abi.encodeCall(IPoppieEulerOracle.setAnchorWindow, ((v % 3) * 1 days));
        if (kind == 5) return abi.encodeCall(IPoppieEulerOracle.setKeeper, (v % 2 == 0 ? backup : address(0xBEEF)));
        if (kind == 6) return abi.encodeCall(IPoppieEulerOracle.transferAdmin, (safe));
        address[] memory one = new address[](1);
        one[0] = a;
        return abi.encodeCall(IPoppieEulerOracle.pauseAssets, (one));
    }

    function submit(uint256 k, uint256 v) external {
        bytes memory d = _candidate(k, v);
        bytes32 id = keccak256(abi.encode(address(oracle), d));
        Snap memory before = _snap();
        vm.prank(safe);
        try g.submit(address(oracle), d) {
            calls++;
            if (g.eta(id) != 0 && queuedAt[id] != g.eta(id)) {
                queuedAt[id] = g.eta(id);
                queuedTs[id] = block.timestamp;
                queuedData.push(d);
            }
            if (_loosened(before, _snap())) violations++; // instant path must never loosen
        } catch {}
    }

    function execute(uint256 i) external {
        if (queuedData.length == 0) return;
        bytes memory d = queuedData[i % queuedData.length];
        bytes32 id = keccak256(abi.encode(address(oracle), d));
        uint256 e = g.eta(id);
        vm.prank(safe);
        try g.execute(address(oracle), d) {
            calls++;
            // forge-lint: disable-next-line(unsafe-typecast) d is abi-encoded calldata: takes its selector
            bool isTransfer = bytes4(d) == IPoppieEulerOracle.transferAdmin.selector;
            uint256 minWait = isTransfer ? g.longDelay() : g.delay();
            if (e == 0 || block.timestamp < queuedTs[id] + minWait) violations++;
        } catch {}
    }

    function approve(uint256 i) external {
        if (queuedData.length == 0) return;
        bytes memory d = queuedData[i % queuedData.length];
        Snap memory before = _snap();
        vm.prank(second);
        try g.approveQueued(address(oracle), d) {
            calls++;
            // forge-lint: disable-next-line(unsafe-typecast) d is abi-encoded calldata: takes its selector
            if (bytes4(d) != IPoppieEulerOracle.adminSetPrice.selector || _loosened(before, _snap())) violations++;
        } catch {}
    }

    function cancel(uint256 i, bool byGuardian) external {
        if (queuedData.length == 0) return;
        bytes32 id = keccak256(abi.encode(address(oracle), queuedData[i % queuedData.length]));
        vm.prank(byGuardian ? guardian : second);
        try g.cancel(id) {
            calls++;
        } catch {}
    }

    function guardianPause(uint256 v) external {
        address[] memory one = new address[](1);
        one[0] = assets[v % 3];
        Snap memory before = _snap();
        vm.prank(guardian);
        try g.pauseAssets(one) {
            calls++;
            if (_loosened(before, _snap())) violations++;
        } catch {}
    }

    /// @dev The guardian trying every non-guardian entry point must always fail.
    function guardianOverreach(uint256 k, uint256 v) external {
        bytes memory d = _candidate(k, v);
        vm.startPrank(guardian);
        try g.submit(address(oracle), d) { violations++; } catch {}
        try g.execute(address(oracle), d) { violations++; } catch {}
        try g.approveQueued(address(oracle), d) { violations++; } catch {}
        try g.setGuardian(guardian) { violations++; } catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }
}

contract OracleAdminGuardInvariantTest is P3Base {
    P3Handler internal h;
    uint256 internal installedAt;

    function setUp() public override {
        super.setUp();
        installedAt = block.timestamp;
        h = new P3Handler(oracle, g, [A, B, C]);
        targetContract(address(h));
    }

    function invariant_noLooseningBeforeEta() public view {
        assertEq(h.violations(), 0);
    }

    function invariant_adminStaysGuard() public view {
        assertEq(oracle.admin(), address(g));
        // a pending transfer can only exist after the long delay
        if (oracle.pendingAdmin() != address(0)) assertGe(block.timestamp, installedAt + LONG);
    }

    /// @dev Sanity: the handler's actions do land (try/catch would otherwise hide a dead handler).
    function test_handlerActionsLand() public {
        h.submit(0, 100e18); // in-band price on A: instant
        h.submit(4, 0); // setAnchorWindow: queued
        h.guardianPause(1); // pause B
        h.warp(1 days);
        h.execute(0);
        h.approve(0);
        assertGe(h.calls(), 4);
        assertEq(h.violations(), 0);
    }

    function invariant_noBalance() public view {
        assertEq(address(g).balance, 0);
    }

    // ── install / exit flows ──
    function test_install_flow() public {
        PoppieEulerOracle o2 = new PoppieEulerOracle(address(this), keeper, 1 days, 1 days);
        OracleAdminGuard g2 =
            new OracleAdminGuard(IPoppieEulerOracle(address(o2)), BAND, DELAY, LONG, safe, second, guardian, backup);
        vm.expectRevert(IPoppieEulerOracle.NoPendingAdmin.selector);
        g2.acceptOracleAdmin();
        o2.transferAdmin(address(g2));
        vm.prank(makeAddr("anyone"));
        g2.acceptOracleAdmin();
        assertEq(o2.admin(), address(g2));
    }

    function test_exit_flow() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.transferAdmin, (safe));
        _submit(d);
        vm.warp(block.timestamp + LONG - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OracleAdminGuard.TooEarly.selector, _id(d)));
        g.execute(address(oracle), d);
        vm.warp(block.timestamp + 1);
        _exec(d);
        assertEq(oracle.pendingAdmin(), safe);
        vm.prank(safe);
        oracle.acceptAdmin();
        assertEq(oracle.admin(), safe);
    }

    function test_exit_guardianCanCancel() public {
        bytes memory d = abi.encodeCall(IPoppieEulerOracle.transferAdmin, (makeAddr("attacker")));
        _submit(d);
        vm.prank(guardian);
        g.cancel(_id(d));
        vm.warp(block.timestamp + LONG);
        vm.prank(safe);
        vm.expectRevert();
        g.execute(address(oracle), d);
        assertEq(oracle.pendingAdmin(), address(0));
    }
}
