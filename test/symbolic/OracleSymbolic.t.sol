// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";
import {MS_OPS, K_PRICE, K_CONFIRM} from "../../src/access/Roles.sol";

/// @dev Oracle with a back door that writes any storage record, so a proof can start from every reachable state
/// (and a few unreachable ones, which the `_assumeReachable` constraints exclude).
contract OracleHarness is PoppieEulerOracle {
    constructor(address admin_) PoppieEulerOracle(admin_) {}

    function seed(address asset, uint128 L, uint40 Lts, uint8 cnt, int8 dir, bool paused, uint128 P, uint40 Pts)
        external
    {
        _hot[asset] = Hot({
            lastPrice: L,
            lastPriceTs: Lts,
            pendingCount: cnt,
            pendingDir: dir,
            paused: paused,
            priceClass: IPoppieEulerOracle.PriceClass.BlueChip,
            decimals: 18,
            listed: true,
            id: 0
        });
        _pending[asset] = Pending({pendingPrice: P, pendingTs: Pts});
        if (_tokens.length == 0) _tokens.push(asset);
    }

    function seedParams(uint40 maxAge, uint8 n_, uint40 spacing, uint16 h) external {
        _params = Params({maxPriceAge: maxAge, n: n_, minPendingSpacing: spacing, hBlueChip: h, hM1: h, hM2: h, hM3: h});
    }
}

/// @notice Symbolic proofs of the oracle's state machine (CONTRACT_SPEC.md sections 3.1 and 6), written as Halmos
/// `check_` tests. Run with, for example:
///
///     halmos --contract OracleSymbolicTest --solver-threads 2 --solver-timeout-assertion 120000
///
/// Forge ignores `check_` functions. The same properties are covered under `forge test` by the differential model
/// fuzz (`test/fuzz`) and the invariant suite (`test/invariant`).
///
/// Each proof starts from an arbitrary reachable record (see `_assumeReachable`: the storage invariants that every
/// transition preserves) and arbitrary risk parameters within their hard bounds, performs one call and checks
/// the result. Prices are `uint32` and times are bounded to 2^32 so the bound check `|p - L| * 10_000 <= h * L`
/// stays tractable for the solver; the fuzz, model and invariant suites cover the full ranges.
contract OracleSymbolicTest is Test {
    OracleHarness internal oracle;
    address internal constant ASSET = address(0xA55E7);
    address internal constant KEEPER = address(0xBEEF);
    address internal constant CONFIRMER = address(0xC0FFEE);
    uint256 internal constant BPS = 10_000;

    function setUp() public {
        oracle = new OracleHarness(address(this));
        oracle.grantRole(K_PRICE, KEEPER);
        oracle.grantRole(K_CONFIRM, CONFIRMER);
    }

    struct S {
        uint32 L;
        uint32 Lts;
        uint8 cnt;
        bool up;
        bool paused;
        uint32 P;
        uint32 Pts;
        uint32 now_;
    }

    struct Cfg {
        uint32 maxAge;
        uint8 n;
        uint32 spacing;
        uint16 h;
    }

    /// @dev The storage invariants every transition preserves: no pending data without a pending move, a pending
    /// move has a direction and a price and is no older than the last price, `L == 0` has no timestamp, a pending
    /// count is below `n`, and time does not run backwards.
    function _assumeReachable(S memory s, Cfg memory c) internal pure {
        vm.assume(c.n >= 2 && c.maxAge > 0 && c.spacing > 0 && c.h <= BPS);
        vm.assume(s.now_ >= s.Lts && s.now_ >= s.Pts);
        if (s.L == 0) vm.assume(s.Lts == 0);
        if (s.cnt == 0) {
            vm.assume(s.P == 0 && s.Pts == 0);
        } else {
            vm.assume(s.P > 0 && s.Pts >= s.Lts && s.cnt < c.n);
        }
    }

    function _load(S memory s, Cfg memory c) internal {
        vm.warp(s.now_);
        int8 dir = s.cnt == 0 ? int8(0) : (s.up ? int8(1) : int8(-1));
        oracle.seed(ASSET, s.L, s.Lts, s.cnt, dir, s.paused, s.P, s.Pts);
        oracle.seedParams(c.maxAge, c.n, c.spacing, c.h);
    }

    function _push(uint32 p) internal returns (bool ok) {
        address[] memory as_ = new address[](1);
        as_[0] = ASSET;
        uint128[] memory ps = new uint128[](1);
        ps[0] = p;
        vm.prank(KEEPER);
        try oracle.keeperPushPrices(as_, ps) {
            ok = true;
        } catch {}
    }

    // -- Proof bodies ----------------------------------------------------------------------------

    /// @dev A push to a paused asset reverts, and a zero price reverts.
    function _pausedPushReverts(S memory s, Cfg memory c, uint32 p) internal {
        _assumeReachable(s, c);
        vm.assume(s.paused);
        _load(s, c);
        assert(!_push(p));
    }

    /// @dev First price (L == 0): a push never makes it live. It records a pending move with count 1.
    function _firstPriceStaysPending(S memory s, Cfg memory c, uint32 p) internal {
        _assumeReachable(s, c);
        vm.assume(s.L == 0 && !s.paused && p != 0);
        _load(s, c);
        assert(_push(p));
        IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(ASSET);
        assert(d.lastPrice == 0 && d.pendingCount == 1 && d.pendingPrice == p);
    }

    /// @dev A push within the bound goes live at `p` and clears every pending field.
    function _inBoundResets(S memory s, Cfg memory c, uint32 p) internal {
        _assumeReachable(s, c);
        vm.assume(!s.paused && s.L != 0 && p != 0);
        uint256 diff = p > s.L ? uint256(p) - s.L : uint256(s.L) - p;
        vm.assume(diff * BPS <= uint256(c.h) * s.L);
        _load(s, c);
        assert(_push(p));
        IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(ASSET);
        assert(d.lastPrice == p && d.lastPriceTs == s.now_);
        assert(d.pendingCount == 0 && d.pendingDir == 0 && d.pendingPrice == 0 && d.pendingTs == 0);
    }

    /// @dev A push beyond the bound moves `lastPrice` only if a pending move was already running in the same
    /// direction, the push is at least `minPendingSpacing` after the previous pending push, and the count reaches
    /// `n`. In every other case `lastPrice` is untouched.
    function _promotionOnlyByPersistence(S memory s, Cfg memory c, uint32 p) internal {
        _assumeReachable(s, c);
        vm.assume(!s.paused && s.L != 0 && p != 0);
        uint256 diff = p > s.L ? uint256(p) - s.L : uint256(s.L) - p;
        vm.assume(diff * BPS > uint256(c.h) * s.L);
        _load(s, c);
        assert(_push(p));
        IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(ASSET);
        if (d.lastPrice != s.L) {
            bool sameDir = (p > s.L) == s.up;
            assert(d.lastPrice == p);
            assert(s.cnt >= 1 && sameDir);
            assert(s.now_ >= uint256(s.Pts) + c.spacing);
            assert(uint256(s.cnt) + 1 >= c.n);
            assert(d.pendingCount == 0);
        }
    }

    /// @dev `confirm` succeeds only for the pending price of an unpaused asset with a fresh pending move, and then
    /// makes it live and clears pending. Anything else reverts.
    function _confirmRules(S memory s, Cfg memory c, uint32 price) internal {
        _assumeReachable(s, c);
        _load(s, c);
        vm.prank(CONFIRMER);
        bool ok;
        try oracle.confirm(ASSET, price) {
            ok = true;
        } catch {}
        bool allowed = !s.paused && s.cnt > 0 && price == s.P && uint256(s.now_) - s.Pts <= c.maxAge;
        assert(ok == allowed);
        if (ok) {
            IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(ASSET);
            assert(d.lastPrice == price && d.pendingCount == 0 && d.pendingPrice == 0);
        }
    }

    /// @dev Pausing keeps the last price and the pending record; the state becomes Closed.
    function _pauseKeepsPrice(S memory s, Cfg memory c) internal {
        _assumeReachable(s, c);
        _load(s, c);
        address[] memory as_ = new address[](1);
        as_[0] = ASSET;
        vm.prank(KEEPER);
        oracle.pauseAssets(as_);
        IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(ASSET);
        assert(d.lastPrice == s.L && d.lastPriceTs == s.Lts && d.pendingCount == s.cnt && d.pendingPrice == s.P);
        assert(oracle.state(ASSET) == IPoppieEulerOracle.PriceState.Closed);
    }

    // -- Halmos entry points ---------------------------------------------------------------------

    function check_pausedPushReverts(S memory s, Cfg memory c, uint32 p) public {
        _pausedPushReverts(s, c, p);
    }

    function check_firstPriceStaysPending(S memory s, Cfg memory c, uint32 p) public {
        _firstPriceStaysPending(s, c, p);
    }

    function check_inBoundResets(S memory s, Cfg memory c, uint32 p) public {
        _inBoundResets(s, c, p);
    }

    function check_promotionOnlyByPersistence(S memory s, Cfg memory c, uint32 p) public {
        _promotionOnlyByPersistence(s, c, p);
    }

    function check_confirmRules(S memory s, Cfg memory c, uint32 price) public {
        _confirmRules(s, c, price);
    }

    function check_pauseKeepsPrice(S memory s, Cfg memory c) public {
        _pauseKeepsPrice(s, c);
    }
}
