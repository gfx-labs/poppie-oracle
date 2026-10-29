// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";

import {MS_OPS, K_PRICE, K_CONFIRM} from "../../src/access/Roles.sol";

import {OracleFixture} from "../harness/OracleFixture.sol";

/// @notice Random action driver for the oracle. Every action takes a before/after snapshot of the affected
/// asset and checks the transition rules of CONTRACT_SPEC.md section 3.1 on the spot, counting violations. The
/// invariant functions in `OracleInvariantsTest` then assert that the count is zero and that the stored state and
/// the adapter's answers satisfy the standing invariants.
contract OracleHandler is Test {
    IPoppieEulerOracle internal immutable oracle;
    address[] internal assets;

    uint256 public violations;
    string public lastViolation;

    // Coverage counters, asserted non-zero in a sanity test so the handler cannot silently stop exercising paths.
    uint256 public pushesIgnored;
    uint256 public promotedByPersistence;
    uint256 public confirmed;
    uint256 public wentLiveInBound;
    uint256 public firstPricePending;
    uint256 public pendingResets;

    constructor(IPoppieEulerOracle oracle_, address[] memory assets_) {
        oracle = oracle_;
        assets = assets_;
    }

    function _violation(string memory what) internal {
        violations++;
        lastViolation = what;
    }

    function _pickAsset(uint256 seed) internal view returns (address) {
        return assets[seed % assets.length];
    }

    function _pickPrice(IPoppieEulerOracle.AssetData memory d, uint256 r) internal view returns (uint256 p) {
        uint256 maxPrice = 1e27;
        uint256 L = d.lastPrice;
        uint256 kind = r % 9;
        r >>= 8;
        if (L == 0 || kind == 8) return (r % maxPrice) + 1;
        uint256 span = L * oracle.haircutBps(d.priceClass) / 10_000;
        if (kind == 0) p = L;
        else if (kind == 1) p = L + span;
        else if (kind == 2) p = L + span + 1;
        else if (kind == 3) p = L > span ? L - span : 1;
        else if (kind == 4) p = L > span + 1 ? L - span - 1 : 1;
        else if (kind == 5) p = L + (r % (span + 1));
        else if (kind == 6) p = L * (2 + r % 5);
        else p = L / (2 + r % 5) + 1;
        if (p > maxPrice) p = maxPrice;
        if (p == 0) p = 1;
    }

    // -- Actions ---------------------------------------------------------------------------------

    function pushAbi(uint256 assetSeed, uint256 r) external {
        _push(assetSeed, r, false);
    }

    function pushPacked(uint256 assetSeed, uint256 r) external {
        _push(assetSeed, r, true);
    }

    function _push(uint256 assetSeed, uint256 r, bool packed) internal {
        address asset = _pickAsset(assetSeed);
        IPoppieEulerOracle.AssetData memory b = oracle.getAssetData(asset);
        uint256 p = _pickPrice(b, r);

        bool ok;
        if (packed) {
            try oracle.keeperPushPacked(PackedPrices.encode(b.id, uint96(p))) {
                ok = true;
            } catch {}
        } else {
            address[] memory as_ = new address[](1);
            as_[0] = asset;
            uint128[] memory ps = new uint128[](1);
            ps[0] = uint128(p);
            try oracle.keeperPushPrices(as_, ps) {
                ok = true;
            } catch {}
        }
        IPoppieEulerOracle.AssetData memory a = oracle.getAssetData(asset);

        if (b.paused) {
            if (ok) _violation("push to a paused asset succeeded");
            return;
        }
        if (!ok) {
            _violation("push to a live-listed asset reverted");
            return;
        }
        _checkPush(b, a, p);
    }

    function _checkPush(IPoppieEulerOracle.AssetData memory b, IPoppieEulerOracle.AssetData memory a, uint256 p)
        internal
    {
        if (a.paused != b.paused || a.id != b.id || a.decimals != b.decimals || a.priceClass != b.priceClass) {
            _violation("push changed static fields");
        }
        // The first price (L == 0) never goes live by a push.
        if (b.lastPrice == 0) {
            if (a.lastPrice != 0) _violation("first price went live by push");
            if (a.pendingCount != 1 || a.pendingPrice != p || a.pendingTs != block.timestamp) {
                _violation("first push not recorded as pending");
            }
            firstPricePending++;
            return;
        }

        uint256 L = b.lastPrice;
        uint256 h = oracle.haircutBps(b.priceClass);
        uint256 d = p > L ? p - L : L - p;
        bool inBound = d * 10_000 <= h * L;

        if (inBound) {
            // A push within the bound goes live and resets pending.
            if (a.lastPrice != p || a.lastPriceTs != block.timestamp) _violation("in-bound push not live");
            if (a.pendingCount != 0 || a.pendingDir != 0 || a.pendingPrice != 0 || a.pendingTs != 0) {
                _violation("in-bound push did not reset pending");
            }
            if (b.pendingCount != 0) pendingResets++;
            wentLiveInBound++;
            return;
        }

        int8 dir = p > L ? int8(1) : int8(-1);
        bool spaced = b.pendingCount == 0 || block.timestamp >= uint256(b.pendingTs) + oracle.minPendingSpacing();

        if (!spaced) {
            // Ignored: nothing at all changes.
            if (keccak256(abi.encode(a)) != keccak256(abi.encode(b))) _violation("unspaced push changed state");
            pushesIgnored++;
            return;
        }

        uint256 expectedCount = (b.pendingCount != 0 && b.pendingDir == dir) ? uint256(b.pendingCount) + 1 : 1;
        if (expectedCount >= oracle.n()) {
            // Promotion by persistence: n spaced pushes in one direction.
            if (a.lastPrice != p || a.lastPriceTs != block.timestamp) _violation("expected promotion did not happen");
            if (b.pendingCount == 0) _violation("promoted without a pending move");
            if (a.pendingCount != 0 || a.pendingPrice != 0 || a.pendingTs != 0) {
                _violation("pending kept after promotion");
            }
            promotedByPersistence++;
        } else {
            if (a.lastPrice != L || a.lastPriceTs != b.lastPriceTs) _violation("price moved without promotion");
            if (a.pendingCount != expectedCount || a.pendingDir != dir) _violation("wrong pending count or direction");
            if (a.pendingPrice != p || a.pendingTs != block.timestamp) _violation("pending not refreshed");
        }
    }

    function confirm(uint256 assetSeed, bool wrong) external {
        address asset = _pickAsset(assetSeed);
        IPoppieEulerOracle.AssetData memory b = oracle.getAssetData(asset);
        uint128 price = wrong ? b.pendingPrice + 1 : b.pendingPrice;
        bool ok;
        try oracle.confirm(asset, price) {
            ok = true;
        } catch {}
        IPoppieEulerOracle.AssetData memory a = oracle.getAssetData(asset);

        bool allowed = !b.paused && b.pendingCount > 0 && price == b.pendingPrice
            && block.timestamp - b.pendingTs <= oracle.maxPriceAge();
        if (ok != allowed) _violation("confirm outcome differs from the rules");
        if (ok) {
            if (a.lastPrice != price || a.lastPriceTs != block.timestamp || a.pendingCount != 0) {
                _violation("confirm did not promote");
            }
            confirmed++;
        } else if (keccak256(abi.encode(a)) != keccak256(abi.encode(b))) {
            _violation("failed confirm changed state");
        }
    }

    function pause(uint256 assetSeed) external {
        address asset = _pickAsset(assetSeed);
        IPoppieEulerOracle.AssetData memory b = oracle.getAssetData(asset);
        address[] memory as_ = new address[](1);
        as_[0] = asset;
        oracle.pauseAssets(as_);
        _checkOnlyPausedChanged(b, oracle.getAssetData(asset), true);
    }

    function unpause(uint256 assetSeed) external {
        address asset = _pickAsset(assetSeed);
        IPoppieEulerOracle.AssetData memory b = oracle.getAssetData(asset);
        address[] memory as_ = new address[](1);
        as_[0] = asset;
        oracle.unpauseAssets(as_);
        _checkOnlyPausedChanged(b, oracle.getAssetData(asset), false);
    }

    /// @dev Pause and unpause keep `lastPrice` and the whole pending record.
    function _checkOnlyPausedChanged(
        IPoppieEulerOracle.AssetData memory b,
        IPoppieEulerOracle.AssetData memory a,
        bool paused
    ) internal {
        if (a.paused != paused) _violation("pause flag not set as asked");
        b.paused = paused;
        if (keccak256(abi.encode(a)) != keccak256(abi.encode(b))) _violation("pause or unpause changed price data");
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 hours));
    }

    function setN(uint256 v) external {
        oracle.setN(uint8(bound(v, 2, 6)));
    }

    function setSpacing(uint256 v) external {
        oracle.setMinPendingSpacing(uint40(bound(v, 1, 30 minutes)));
    }

    function setMaxAge(uint256 v) external {
        oracle.setMaxPriceAge(uint40(bound(v, 20 minutes, 2 hours)));
    }

    function setHaircut(uint256 c, uint256 bps) external {
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass(bound(c, 0, 3)), uint16(bound(bps, 0, 10_000)));
    }

    function setClass(uint256 assetSeed, uint256 c) external {
        oracle.setAssetClass(_pickAsset(assetSeed), IPoppieEulerOracle.PriceClass(bound(c, 0, 3)));
    }
}

/// @notice Invariants of the oracle (CONTRACT_SPEC.md section 3.1 / 6) and of the adapter on top of it
/// (section 3.2), under random sequences of pushes in both formats, confirms, pauses, time and param changes.
///
/// forge-config: default.invariant.depth = 120
/// forge-config: ci.invariant.depth = 120
contract OracleInvariantsTest is OracleFixture {
    OracleHandler internal handler;
    address[] internal assets;

    function setUp() public override {
        super.setUp();
        assets.push(address(tokenA));
        assets.push(address(tokenB));
        assets.push(address(tokenC));
        handler = new OracleHandler(oracle, assets);

        // The handler plays every role; the transitions it checks do not depend on who calls.
        vm.startPrank(admin);
        impl.grantRole(K_PRICE, address(handler));
        impl.grantRole(K_CONFIRM, address(handler));
        impl.grantRole(MS_OPS, address(handler));
        vm.stopPrank();

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = handler.pushAbi.selector;
        sels[10] = handler.pushPacked.selector;
        sels[1] = handler.confirm.selector;
        sels[2] = handler.pause.selector;
        sels[3] = handler.unpause.selector;
        sels[4] = handler.warp.selector;
        sels[5] = handler.setN.selector;
        sels[6] = handler.setSpacing.selector;
        sels[7] = handler.setMaxAge.selector;
        sels[8] = handler.setHaircut.selector;
        sels[9] = handler.setClass.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_noTransitionViolations() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    function invariant_storedRecordsAreConsistent() public view {
        for (uint256 i; i < assets.length; ++i) {
            IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(assets[i]);
            assertTrue(d.listed);
            if (d.pendingCount == 0) {
                assertEq(d.pendingDir, 0);
                assertEq(d.pendingPrice, 0);
                assertEq(d.pendingTs, 0);
            } else {
                assertTrue(d.pendingDir == 1 || d.pendingDir == -1);
                assertGt(d.pendingPrice, 0);
                assertGt(d.pendingTs, 0);
                assertGe(d.pendingTs, d.lastPriceTs);
            }
            if (d.lastPrice == 0) assertEq(d.lastPriceTs, 0);
            else assertGt(d.lastPriceTs, 0);
            // No confirmed price ever disappears: an asset that has one never reads 0 again (checked through the
            // adapter below as well).
            if (d.lastPrice == 0) {
                assertTrue(d.pendingCount <= 1, "first price is never counted up");
                assertTrue(oracle.state(assets[i]) != IPoppieEulerOracle.PriceState.Live, "live without a price");
            }
        }
    }

    function invariant_stateIsDerivedConsistently() public view {
        for (uint256 i; i < assets.length; ++i) {
            IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(assets[i]);
            IPoppieEulerOracle.PriceState s = oracle.state(assets[i]);
            if (d.paused) assertTrue(s == IPoppieEulerOracle.PriceState.Closed, "paused must be closed");
            if (s == IPoppieEulerOracle.PriceState.Live) {
                assertTrue(!d.paused && d.pendingCount == 0 && d.lastPrice > 0, "live preconditions");
                assertLe(block.timestamp - d.lastPriceTs, oracle.maxPriceAge());
            }
            if (s == IPoppieEulerOracle.PriceState.Unconfirmed) {
                assertTrue(!d.paused && d.pendingCount > 0, "unconfirmed preconditions");
            }
            IPoppieEulerOracle.QuoteData memory q = oracle.getQuoteData(assets[i]);
            assertEq(uint8(q.state), uint8(s));
            assertEq(q.lastPrice, d.lastPrice);
            assertEq(q.haircutBps, oracle.haircutBps(d.priceClass));
        }
    }

    function invariant_adapter() public view {
        for (uint256 i; i < assets.length; ++i) {
            address base = assets[i];
            IPoppieEulerOracle.QuoteData memory q = oracle.getQuoteData(base);
            uint256 unit = 10 ** q.decimals;
            uint256[4] memory amounts = [uint256(1), unit, 3 * unit + 7, 1e30];
            for (uint256 k; k < amounts.length; ++k) {
                _checkAdapter(base, q, amounts[k]);
            }
        }
    }

    function _checkAdapter(address base, IPoppieEulerOracle.QuoteData memory q, uint256 amount) internal view {
        (uint256 bid, uint256 ask) = adapter.getQuotes(amount, base, address(840));
        assertLe(bid, ask, "bid <= ask");

        (bool ok, bytes memory ret) =
            address(adapter).staticcall(abi.encodeCall(IPriceOracle.getQuote, (amount, base, address(840))));

        if (q.state == IPoppieEulerOracle.PriceState.Live) {
            assertTrue(ok, "mid defined when Live");
            uint256 mid = abi.decode(ret, (uint256));
            assertLe(bid, mid, "bid <= mid");
            assertLe(mid, ask, "mid <= ask");
        } else {
            assertTrue(!ok, "mid must revert when not Live");
            bytes4 expected = q.state == IPoppieEulerOracle.PriceState.Closed
                ? IPoppieEulerAdapter.PriceUnavailable.selector
                : IPoppieEulerAdapter.PriceUnconfirmed.selector;
            assertEq(bytes4(ret), expected, "wrong revert");
            // The bid never exceeds L * (1 - h) before a move is confirmed.
            uint256 cap =
                Math.mulDiv(amount, uint256(q.lastPrice) * (10_000 - q.haircutBps), (10 ** q.decimals) * 10_000);
            assertLe(bid, cap, "bid above L(1-h)");
        }
        if (q.lastPrice == 0) assertEq(bid, 0, "bid must be 0 while L == 0");
    }
}

/// @notice Pins that the handler can reach each transition, with a fixed scripted sequence.
contract OracleHandlerCoverageTest is OracleFixture {
    function test_handlerReachesEveryPath() public {
        address[] memory as_ = new address[](1);
        as_[0] = address(tokenA);
        OracleHandler h = new OracleHandler(oracle, as_);
        vm.startPrank(admin);
        impl.grantRole(K_PRICE, address(h));
        impl.grantRole(K_CONFIRM, address(h));
        impl.grantRole(MS_OPS, address(h));
        vm.stopPrank();

        // r % 9 selects the price kind (8: random, 0: unchanged, 1: edge, 2: beyond up, 6: far above).
        h.pushAbi(0, 8); // first price, pending
        h.confirm(0, false); // confirmed
        h.pushPacked(0, 1); // upper edge, in bound
        h.pushAbi(0, 2); // beyond: pending 1
        h.pushPacked(0, 2); // inside spacing: ignored
        h.warp(10 minutes);
        h.pushAbi(0, 2); // pending 2
        h.warp(10 minutes);
        h.pushPacked(0, 2); // pending 3: promoted by persistence
        h.pushAbi(0, 2); // pending again
        h.pushAbi(0, 0); // in bound: pending reset
        assertEq(h.violations(), 0, h.lastViolation());
        assertGt(h.firstPricePending(), 0);
        assertGt(h.confirmed(), 0);
        assertGt(h.wentLiveInBound(), 0);
        assertGt(h.pushesIgnored(), 0);
        assertGt(h.promotedByPersistence(), 0);
        assertGt(h.pendingResets(), 0);
    }
}
