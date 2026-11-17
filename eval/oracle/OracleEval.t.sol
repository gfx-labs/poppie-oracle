// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Evaluation tests for docs/evaluation/Contracts.md, section A. They exercise the
// unmodified v1 oracle and adapter and compile under the audited settings
// (FOUNDRY_PROFILE=eval-oracle) as well as the full eval profile.

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

/// @dev Stand-in for a Safe or timelock: forwards arbitrary calls from its owner.
contract CallForwarder {
    address internal immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "owner");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

contract OracleEvalTest is Test {
    PoppieEulerOracle internal o;
    address internal constant KEEPER = address(0xBEEF);
    address internal constant USD = address(840);
    address internal a1 = address(0x1001);
    address internal a2 = address(0x1002);
    address internal a3 = address(0x1003);

    uint256 internal constant MAX_AGE = 3 days;
    uint256 internal constant WINDOW = 1 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        o = new PoppieEulerOracle(address(this), KEEPER, MAX_AGE, WINDOW);
        address[] memory as_ = new address[](3);
        as_[0] = a1;
        as_[1] = a2;
        as_[2] = a3;
        uint16[] memory t = new uint16[](3);
        for (uint256 i; i < 3; ++i) t[i] = 5000; // dev-script single-stock default
        o.configureAssets(as_, t, t);
        for (uint256 i; i < 3; ++i) o.adminSetPrice(as_[i], 100e18);
    }

    // ── helpers ─────────────────────────────────────────────────────────

    function _push(address a, uint128 p) internal {
        address[] memory x = new address[](1);
        x[0] = a;
        uint128[] memory y = new uint128[](1);
        y[0] = p;
        vm.prank(KEEPER);
        o.keeperPushPrices(x, y);
    }

    function _one(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    /// A real 18-decimal token configured and seeded at `price` on `oracle`.
    function _token(PoppieEulerOracle oracle, uint128 price) internal returns (address t) {
        t = address(new MockERC20("T", "T", 18));
        uint16[] memory c = new uint16[](1);
        c[0] = 5000;
        oracle.configureAssets(_one(t), c, c);
        oracle.adminSetPrice(t, price);
    }

    function _configureN(uint256 n, uint256 offset) internal returns (address[] memory x) {
        x = new address[](n);
        uint16[] memory c = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = address(uint160(0x100000 + offset + i));
            c[i] = 5000;
        }
        o.configureAssets(x, c, c);
    }

    // ── A1: batch atomicity ─────────────────────────────────────────────

    function test_A1_oneBadEntryRevertsWholeBatch() public {
        address[] memory x = new address[](3);
        x[0] = a1;
        x[1] = a2;
        x[2] = a3;
        uint128[] memory y = new uint128[](3);
        y[0] = 101e18;
        y[1] = 10e18; // -90%, trips the breaker
        y[2] = 101e18;
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, a2, 9000, 5000));
        o.keeperPushPrices(x, y);
        assertEq(o.getAssetConfig(a1).lastPrice, 100e18, "a1 not written");
        assertEq(o.getAssetConfig(a3).lastPrice, 100e18, "a3 not written");
    }

    function test_A1_unconfiguredAssetRevertsBatch() public {
        address[] memory x = new address[](2);
        x[0] = a1;
        x[1] = address(0xDEAD);
        uint128[] memory y = new uint128[](2);
        y[0] = 101e18;
        y[1] = 1e18;
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotConfigured.selector, address(0xDEAD)));
        o.keeperPushPrices(x, y);
    }

    // ── A2: thresholds ──────────────────────────────────────────────────

    function test_A2_thresholdBounds() public {
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        o.setAssetThresholds(a1, 10_001, 5000);
        vm.expectRevert(IPoppieEulerOracle.InvalidConfig.selector);
        o.setAssetThresholds(a1, 5000, 0); // cumulative cap can never be disabled
        o.setAssetThresholds(a1, 0, 10_000); // breaker can be disabled, cap at max
        vm.prank(KEEPER);
        vm.expectRevert(IPoppieEulerOracle.OnlyAdmin.selector);
        o.setAssetThresholds(a1, 3000, 3000);
    }

    /// Breaker passes iff floor(|new-old| * 1e4 / old) <= threshold. Anchor
    /// window is expired so only the breaker binds.
    function testFuzz_A2_breakerBoundary(uint128 oldP, uint128 newP, uint16 thr) public {
        oldP = uint128(bound(oldP, 1e6, 1e30));
        newP = uint128(bound(newP, 1, 1e30));
        thr = uint16(bound(thr, 1, 10_000));
        o.setAssetThresholds(a1, thr, 10_000);
        o.adminSetPrice(a1, oldP);
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 diff = newP > oldP ? newP - oldP : oldP - newP;
        uint256 dev = diff * 10_000 / oldP;
        if (dev > thr) {
            vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, a1, dev, thr));
        }
        _push(a1, newP);
        if (dev <= thr) assertEq(o.getAssetConfig(a1).lastPrice, newP);
    }

    // ── Corporate actions on a per-token price ──────────────────────────

    /// An unadjusted 2:1 split is exactly -50% and the check is a strict '>',
    /// so it passes the 5000 bps dev default, after the window rotates...
    function test_split2to1_mispush_passes_afterRotation() public {
        vm.warp(block.timestamp + WINDOW + 1);
        _push(a1, 50e18);
        assertEq(uint256(o.getPrice(a1)), 50e18);
    }

    /// ...and inside the anchor window too (cumulative cap also 5000).
    function test_split2to1_mispush_passes_withinWindow() public {
        _push(a1, 50e18);
        assertEq(uint256(o.getPrice(a1)), 50e18);
    }

    /// A 3:1 split (-66.7%) cannot be pushed by the keeper at 5000 bps.
    function test_split3to1_needsAdmin() public {
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, a1, 6666, 5000));
        _push(a1, 33.333e18);
        o.adminSetPrice(a1, 33.333e18);
        assertEq(uint256(o.getPrice(a1)), 33.333e18);
    }

    /// Moves above +100% can never be pushed by the keeper (max 10000 bps).
    function test_reverseSplit1to3_needsAdminEvenAtMaxThresholds() public {
        o.setAssetThresholds(a1, 10_000, 10_000);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, a1, 20_000, 10_000));
        _push(a1, 300e18);
    }

    // ── A3: staleness gap and resume ────────────────────────────────────

    function test_A3_freezeThenResumeWithoutAdmin() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        o.getPrice(a1);
        _push(a1, 130e18); // +30% Monday gap, inside the breaker
        assertEq(uint256(o.getPrice(a1)), 130e18);
        // the anchor rotated to the accepted price, so the next window starts there
        assertEq(o.getAssetConfig(a1).anchorPrice, 130e18);
    }

    function test_A3_gapBeyondBreakerNeedsAdmin() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, a1, 6000, 5000));
        _push(a1, 160e18);
        // still stale until the admin re-seeds
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        o.getPrice(a1);
    }

    /// Within the window, drift is bounded cumulatively across pushes.
    function test_A3_cumulativeCapBindsWithinWindow() public {
        o.setAssetThresholds(a1, 3000, 4000);
        _push(a1, 125e18); // +25% vs anchor 100
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.CumulativeDeviationExceeded.selector, a1, 5000, 4000));
        _push(a1, 150e18); // +20% step, but +50% vs anchor
    }

    // ── A4: pause and recovery ──────────────────────────────────────────

    function test_A4_pauseWipesStateAndNeedsAdminPlusKeeper() public {
        vm.prank(KEEPER);
        o.pauseAssets(_one(a1));
        IPoppieEulerOracle.AssetConfig memory c = o.getAssetConfig(a1);
        assertTrue(c.paused);
        assertEq(c.lastPrice, 0);
        assertEq(c.anchorPrice, 0);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, a1));
        _push(a1, 100e18);
        o.adminSetPrice(a1, 100e18);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, a1));
        o.getPrice(a1); // still paused after the admin seed (audit L-02)
        _push(a1, 100e18);
        assertEq(uint256(o.getPrice(a1)), 100e18);
    }

    function test_A4_pauseBatchRevertsIfAnyAlreadyPaused() public {
        o.pauseAssets(_one(a2));
        address[] memory z = new address[](2);
        z[0] = a1;
        z[1] = a2;
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetAlreadyPaused.selector, a2));
        o.pauseAssets(z);
        assertFalse(o.getAssetConfig(a1).paused, "a1 not paused");
    }

    // ── A5: staleness boundaries ────────────────────────────────────────

    function test_A5_staleBoundaryAndOverride() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + MAX_AGE);
        o.getPrice(a1); // age == maxAge is fresh
        vm.warp(t0 + MAX_AGE + 1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        o.getPrice(a1);

        // a per-asset override wins over the global value
        o.setAssetMaxPriceAge(a1, uint40(MAX_AGE * 2));
        o.getPrice(a1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        o.getPrice(a2);

        // both zero disables the check
        o.setAssetMaxPriceAge(a2, 0);
        o.setMaxPriceAge(0);
        vm.warp(t0 + 365 days);
        o.getPrice(a2);
    }

    // ── A6: roles ───────────────────────────────────────────────────────

    function test_A6_adminCanBeAContract_singleKeeper() public {
        CallForwarder safe = new CallForwarder();
        o.transferAdmin(address(safe));
        safe.exec(address(o), abi.encodeCall(o.acceptAdmin, ()));
        assertEq(o.admin(), address(safe));

        // the old admin has lost every power, including price writes
        vm.expectRevert(IPoppieEulerOracle.OnlyAdmin.selector);
        o.adminSetPrice(a1, 1e18);
        safe.exec(address(o), abi.encodeCall(o.adminSetPrice, (a1, 101e18)));

        // there is exactly one keeper; a second key cannot push
        address backupKeeper = address(0xB0B);
        vm.prank(backupKeeper);
        vm.expectRevert(IPoppieEulerOracle.OnlyKeeper.selector);
        o.keeperPushPrices(_one(a1), new uint128[](1));

        // failover needs an admin call
        safe.exec(address(o), abi.encodeCall(o.setKeeper, (backupKeeper)));
        uint128[] memory p = new uint128[](1);
        p[0] = 102e18;
        vm.prank(backupKeeper);
        o.keeperPushPrices(_one(a1), p);
    }

    // ── A7: scale ───────────────────────────────────────────────────────

    function _gasPush(uint256 n) internal returns (uint256 configureGas, uint256 seedGas, uint256 pushGas) {
        address[] memory x = new address[](n);
        uint16[] memory c = new uint16[](n);
        uint128[] memory p = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = address(uint160(0x200000 + i));
            c[i] = 5000;
            p[i] = 101e18;
        }
        uint256 g = gasleft();
        o.configureAssets(x, c, c);
        configureGas = g - gasleft();
        g = gasleft();
        for (uint256 i; i < n; ++i) o.adminSetPrice(x[i], 100e18); // MultiSend-like loop
        seedGas = g - gasleft();
        vm.warp(block.timestamp + 60);
        vm.prank(KEEPER);
        g = gasleft();
        o.keeperPushPrices(x, p);
        pushGas = g - gasleft();
    }

    function test_A7_gas100() public {
        (uint256 c, uint256 s, uint256 p) = _gasPush(100);
        emit log_named_uint("configure 100", c);
        emit log_named_uint("seed 100", s);
        emit log_named_uint("push 100", p);
    }

    function test_A7_gas250() public {
        (uint256 c, uint256 s, uint256 p) = _gasPush(250);
        emit log_named_uint("configure 250", c);
        emit log_named_uint("seed 250", s);
        emit log_named_uint("push 250", p);
    }

    /// 500 assets: configure, seed and push each fit well under 32M gas.
    function test_A7_gas500() public {
        (uint256 c, uint256 s, uint256 p) = _gasPush(500);
        emit log_named_uint("configure 500", c);
        emit log_named_uint("seed 500", s);
        emit log_named_uint("push 500", p);
        assertLt(c, 32_000_000);
        assertLt(s, 32_000_000);
        assertLt(p, 32_000_000);
    }

    /// Reads are O(1): gas for getPrice does not depend on the asset count.
    function test_A7_readIsConstant() public {
        o.getPrice(a3); // warm the contract and globals; a1 and a2 slots stay cold
        uint256 g = gasleft();
        o.getPrice(a1);
        uint256 small = g - gasleft();
        _configureN(400, 0);
        g = gasleft();
        o.getPrice(a2);
        uint256 large = g - gasleft();
        assertApproxEqAbs(large, small, 200);
    }

    // ── A9 / A10: adapter ───────────────────────────────────────────────

    function test_A9_bidEqualsAsk_quoteOnlyUsd_revertsPropagate() public {
        address t = _token(o, 100e18);
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(t, 18);
        (uint256 bid, uint256 ask) = ad.getQuotes(2e18, t, USD);
        assertEq(bid, ask);
        assertEq(bid, 200e18);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.UnsupportedQuote.selector, a2));
        ad.getQuote(1e18, t, a2);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        ad.getQuote(1e18, t, USD);
    }

    /// registerBase calls decimals() inside try/catch, but a base with no code
    /// reverts in the caller (return-data decode), so it is not caught.
    /// Harmless for real tokens; scripts must register deployed contracts only.
    function test_A10_codelessBaseCannotBeRegistered() public {
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        vm.expectRevert();
        ad.registerBase(a1, 18);
    }

    function test_A10_decimalsBound() public {
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.DecimalsTooLarge.selector, 19));
        ad.registerBase(a1, 19);
        address t = _token(o, 1e18);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.DecimalsMismatch.selector, 6, 18));
        ad.registerBase(t, 6);
    }

    // ── A11: several instances coexist ──────────────────────────────────

    function test_A11_independentInstances() public {
        PoppieEulerOracle o2 = new PoppieEulerOracle(address(this), address(0xCAFE), MAX_AGE, WINDOW);
        address t = _token(o, 100e18);
        uint16[] memory c = new uint16[](1);
        c[0] = 3000;
        o2.configureAssets(_one(t), c, c);
        o2.adminSetPrice(t, 55e18);
        PoppieEulerAdapter ad1 = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        PoppieEulerAdapter ad2 = new PoppieEulerAdapter(address(o2), address(this), USD, 6);
        ad1.registerBase(t, 18);
        ad2.registerBase(t, 18);
        assertEq(ad1.getQuote(1e18, t, USD), 100e18);
        assertEq(ad2.getQuote(1e18, t, USD), 55e6);
        // a keeper on one instance has no power on the other
        uint128[] memory p = new uint128[](1);
        p[0] = 1e18;
        vm.prank(KEEPER);
        vm.expectRevert(IPoppieEulerOracle.OnlyKeeper.selector);
        o2.keeperPushPrices(_one(t), p);
    }
}
