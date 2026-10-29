// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";

import {OracleFixture} from "../harness/OracleFixture.sol";

/// @notice Differential fuzz of every state transition. A reference model written line by line from
/// CONTRACT_SPEC.md section 3.1 / 3.2 runs next to the real oracle and adapter over random action sequences
/// (pushes in both formats, duplicate-entry batches, confirms right and wrong, pause, unpause, time, and every
/// risk-param setter). After each step the stored record, the derived state, the quote data and the adapter's
/// mid, bid and ask must equal the model's, and a call must revert exactly when the model says it does.
contract PoppieEulerOracleModelTest is OracleFixture {
    // -- Reference model -------------------------------------------------------------------------

    uint256 internal mL; // last confirmed price
    uint256 internal mLts;
    uint256 internal mCnt;
    int256 internal mDir;
    uint256 internal mP; // pending price
    uint256 internal mPts;
    bool internal mPaused;
    uint256 internal mClass;

    uint256 internal mN = 3;
    uint256 internal mSpacing = 10 minutes;
    uint256 internal mMaxAge = 1 hours;
    uint256[4] internal mH = [uint256(1000), 1500, 2000, 3000];

    uint256 internal constant MAX_PRICE = 1e27; // below the uint96 ceiling of the packed format

    address internal a;

    function setUp() public override {
        super.setUp();
        a = address(tokenA);
    }

    function _mPush(uint256 p) internal returns (bool ok) {
        if (mPaused || p == 0) return false;
        if (mL == 0) {
            mP = p;
            mPts = block.timestamp;
            mCnt = 1;
            mDir = 1;
            return true;
        }
        uint256 d = p > mL ? p - mL : mL - p;
        if (d * 10_000 <= mH[mClass] * mL) {
            mL = p;
            mLts = block.timestamp;
            mCnt = 0;
            mDir = 0;
            mP = 0;
            mPts = 0;
            return true;
        }
        int256 dir = p > mL ? int256(1) : int256(-1);
        if (mCnt > 0 && block.timestamp < mPts + mSpacing) return true; // ignored
        if (mCnt > 0 && dir == mDir) {
            mCnt += 1;
        } else {
            mCnt = 1;
            mDir = dir;
        }
        mP = p;
        mPts = block.timestamp;
        if (mCnt >= mN) {
            mL = p;
            mLts = block.timestamp;
            mCnt = 0;
            mDir = 0;
            mP = 0;
            mPts = 0;
        }
        return true;
    }

    function _mConfirm(uint256 price) internal returns (bool ok) {
        if (mPaused || mCnt == 0 || price != mP || block.timestamp - mPts > mMaxAge) return false;
        mL = mP;
        mLts = block.timestamp;
        mCnt = 0;
        mDir = 0;
        mP = 0;
        mPts = 0;
        return true;
    }

    function _mState() internal view returns (IPoppieEulerOracle.PriceState) {
        uint256 touched = mLts > mPts ? mLts : mPts;
        if (mPaused || block.timestamp - touched > mMaxAge) return IPoppieEulerOracle.PriceState.Closed;
        return mCnt > 0 ? IPoppieEulerOracle.PriceState.Unconfirmed : IPoppieEulerOracle.PriceState.Live;
    }

    // -- Driving the real contracts --------------------------------------------------------------

    function _tryPush(uint256[] memory prices, bool packed) internal returns (bool ok) {
        vm.prank(keeper);
        if (packed) {
            bytes memory data;
            for (uint256 i; i < prices.length; ++i) {
                data = bytes.concat(data, PackedPrices.encode(1, uint96(prices[i])));
            }
            try oracle.keeperPushPacked(data) {
                return true;
            } catch {
                return false;
            }
        }
        address[] memory as_ = new address[](prices.length);
        uint128[] memory ps = new uint128[](prices.length);
        for (uint256 i; i < prices.length; ++i) {
            as_[i] = a;
            ps[i] = uint128(prices[i]);
        }
        try oracle.keeperPushPrices(as_, ps) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev A price relative to the model's `L`: inside the bound, on its edge, just beyond, far beyond.
    function _pickPrice(uint256 r) internal view returns (uint256 p) {
        uint256 L = mL;
        uint256 kind = r % 9;
        r >>= 8;
        if (L == 0 || kind == 8) return (r % MAX_PRICE) + 1;
        uint256 span = L * mH[mClass] / 10_000;
        if (kind == 0) p = L; // unchanged
        else if (kind == 1) p = L + span; // upper edge, in bound
        else if (kind == 2) p = L + span + 1; // just beyond, up
        else if (kind == 3) p = L > span ? L - span : 1; // lower edge (in bound unless clamped)
        else if (kind == 4) p = L > span + 1 ? L - span - 1 : 1; // just beyond, down
        else if (kind == 5) p = L + (r % (span + 1)); // inside, up
        else if (kind == 6) p = L * (2 + r % 5); // far above
        else p = L / (2 + r % 5) + 1; // far below
        if (p > MAX_PRICE) p = MAX_PRICE;
        if (p == 0) p = 1;
    }

    function _step(uint256 r) internal {
        uint256 kind = r % 14;
        r >>= 8;
        if (kind <= 3) {
            uint256[] memory ps = new uint256[](1);
            ps[0] = _pickPrice(r);
            bool packed = kind >= 2;
            bool ok = _tryPush(ps, packed);
            assertEq(ok, _mPush(ps[0]), "push success differs");
        } else if (kind == 4) {
            // Batch with duplicate entries for one asset, in a random format.
            uint256 len = 2 + (r >> 8) % 4;
            uint256[] memory ps = new uint256[](len);
            // Prices of a batch are all picked against the state before it.
            for (uint256 i; i < len; ++i) {
                ps[i] = _pickPrice(uint256(keccak256(abi.encode(r, i))));
            }
            bool ok = _tryPush(ps, (r >> 4) % 2 == 0);
            bool mok = !mPaused;
            if (mok) {
                for (uint256 i; i < len; ++i) {
                    _mPush(ps[i]);
                }
            }
            assertEq(ok, mok, "batch success differs");
        } else if (kind <= 6) {
            // Confirm: mostly the right price, sometimes a wrong one.
            uint256 price = (r % 5 == 0) ? mP + 1 + r % 3 : mP;
            if (price == 0) price = 1;
            vm.prank(confirmer);
            bool ok;
            try oracle.confirm(a, uint128(price)) {
                ok = true;
            } catch {}
            assertEq(ok, _mConfirm(price), "confirm success differs");
        } else if (kind == 7) {
            address[] memory as_ = new address[](1);
            as_[0] = a;
            vm.prank(keeper);
            oracle.pauseAssets(as_);
            mPaused = true;
        } else if (kind == 8) {
            _unpause(a);
            mPaused = false;
        } else if (kind == 9) {
            uint256 pick = r % 8;
            uint256 dt = pick == 0
                ? 0
                : pick == 1
                    ? 1
                    : pick == 2
                        ? mSpacing - 1
                        : pick == 3 ? mSpacing : pick == 4 ? mMaxAge : pick == 5 ? mMaxAge + 1 : (r >> 4) % 3 hours;
            vm.warp(block.timestamp + dt);
        } else if (kind == 10) {
            mN = 2 + r % 5;
            vm.prank(ops);
            oracle.setN(uint8(mN));
        } else if (kind == 11) {
            uint256 which = r % 3;
            uint256 v = (r >> 4) % 40 minutes + 1;
            vm.startPrank(ops);
            if (which == 0) {
                mSpacing = v;
                oracle.setMinPendingSpacing(uint40(v));
            } else if (which == 1) {
                mMaxAge = v + 20 minutes;
                oracle.setMaxPriceAge(uint40(mMaxAge));
            } else {
                uint256 c = (r >> 4) % 4;
                uint256 bps = (r >> 8) % 10_001;
                mH[c] = bps;
                oracle.setClassHaircut(IPoppieEulerOracle.PriceClass(c), uint16(bps));
            }
            vm.stopPrank();
        } else if (kind == 12) {
            mClass = r % 4;
            vm.prank(ops);
            oracle.setAssetClass(a, IPoppieEulerOracle.PriceClass(mClass));
        } else {
            // A tiny time step, so same-second and next-second pushes are both well covered.
            vm.warp(block.timestamp + 1);
        }
        _compare();
    }

    function _compare() internal {
        IPoppieEulerOracle.AssetData memory d = oracle.getAssetData(a);
        assertEq(d.lastPrice, mL, "L");
        assertEq(d.lastPriceTs, mLts, "Lts");
        assertEq(d.pendingCount, mCnt, "count");
        assertEq(int256(d.pendingDir), mDir, "dir");
        assertEq(d.pendingPrice, mP, "P");
        assertEq(d.pendingTs, mPts, "Pts");
        assertEq(d.paused, mPaused, "paused");
        assertEq(uint8(d.priceClass), mClass, "class");

        IPoppieEulerOracle.PriceState s = _mState();
        assertEq(uint8(oracle.state(a)), uint8(s), "state");
        IPoppieEulerOracle.QuoteData memory q = oracle.getQuoteData(a);
        assertEq(uint8(q.state), uint8(s));
        assertEq(q.lastPrice, mL);
        assertEq(q.pendingPrice, mP);
        assertEq(q.haircutBps, mH[mClass]);
        assertEq(q.decimals, 18);

        // Adapter against the table of CONTRACT_SPEC.md 3.2. One whole 18-decimals token, so the output is the
        // price itself.
        uint256 hBps = mH[mClass];
        uint256 haircutL = mL * (10_000 - hBps) / 10_000;
        if (s == IPoppieEulerOracle.PriceState.Live) {
            assertEq(adapter.getQuote(1e18, a, address(840)), mL);
            (uint256 bid, uint256 ask) = adapter.getQuotes(1e18, a, address(840));
            assertEq(bid, mL);
            assertEq(ask, mL);
        } else {
            vm.expectRevert(
                s == IPoppieEulerOracle.PriceState.Closed
                    ? IPoppieEulerAdapter.PriceUnavailable.selector
                    : IPoppieEulerAdapter.PriceUnconfirmed.selector
            );
            adapter.getQuote(1e18, a, address(840));
            (uint256 bid, uint256 ask) = adapter.getQuotes(1e18, a, address(840));
            if (s == IPoppieEulerOracle.PriceState.Closed) {
                assertEq(bid, haircutL);
                assertEq(ask, mL);
            } else {
                assertEq(bid, mP < haircutL ? mP : haircutL);
                assertEq(ask, mP > mL ? mP : mL);
            }
            assertLe(bid, haircutL, "bid above L(1-h) before confirmation");
            assertLe(bid, ask);
        }
    }

    // -- The fuzz entry points -------------------------------------------------------------------

    /// @dev Starts from a never-priced asset, so first-price handling is covered too.
    function testFuzz_modelMatches_fromNeverPriced(uint256 seed) public {
        for (uint256 i; i < 48; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
        }
    }

    /// @dev Starts from a confirmed price.
    function testFuzz_modelMatches_fromLive(uint256 seed, uint96 start) public {
        uint256 p = bound(start, 1e6, MAX_PRICE);
        _push(a, uint128(p));
        _mPush(p);
        _confirm(a, uint128(p));
        _mConfirm(p);
        _compare();
        for (uint256 i; i < 48; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
        }
    }
}
