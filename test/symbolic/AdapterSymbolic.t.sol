// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {PoppieEulerAdapter} from "../../src/oracle/PoppieEulerAdapter.sol";

/// @dev Returns whatever quote data it is given. Stands in for the oracle so the adapter can be proven for every
/// state, `L`, `P` and `h` at once.
contract QuoteDataStub {
    IPoppieEulerOracle.QuoteData internal q;

    function set(IPoppieEulerOracle.PriceState s, uint128 L, uint128 P, uint16 h, uint8 dec) external {
        q = IPoppieEulerOracle.QuoteData({state: s, lastPrice: L, pendingPrice: P, haircutBps: h, decimals: dec});
    }

    function getQuoteData(address) external view returns (IPoppieEulerOracle.QuoteData memory) {
        return q;
    }
}

/// @dev Exposes the adapter's price selection and its conversion.
contract AdapterHarness is PoppieEulerAdapter {
    constructor(IPoppieEulerOracle o) PoppieEulerAdapter(o) {}

    function bidAskBps(uint8 s, uint128 L, uint128 P, uint16 h) external pure returns (uint256, uint256) {
        return _bidAskBps(
            IPoppieEulerOracle.QuoteData({
                state: IPoppieEulerOracle.PriceState(s), lastPrice: L, pendingPrice: P, haircutBps: h, decimals: 18
            })
        );
    }
}

/// @notice Symbolic proofs for `PoppieEulerAdapter` (CONTRACT_SPEC.md sections 3.2 and 6), written as Halmos
/// `check_` tests. Run one at a time:
///
///     halmos --contract AdapterSymbolicTest --function check_bidAsk_ordering --solver-threads 2
///
/// Forge ignores `check_` functions. Each proof body also has a `testFuzz_` twin that runs under `forge test`, so
/// the properties are exercised in CI even where Halmos is not installed.
///
/// Prices are proved for every `uint128` except the ordering proof, which is limited to `uint64` (see
/// `check_bidAsk_ordering`).
///
/// Scope: the proofs cover the price selection (`_bidAskBps`: which price is the bid and which the ask in each
/// state, for every `L`, `P` and `h <= 10_000`) and the revert behaviour of the mid. The final scaling by
/// `10 ** decimals` (`Math.mulDiv` from OpenZeppelin) is monotone, so the ordering carries over; that step is
/// checked by the fuzz and invariant suites, not by the solver (512-bit division is not tractable).
contract AdapterSymbolicTest is Test {
    uint256 internal constant BPS = 10_000;
    uint8 internal constant CLOSED = uint8(IPoppieEulerOracle.PriceState.Closed);
    uint8 internal constant UNCONFIRMED = uint8(IPoppieEulerOracle.PriceState.Unconfirmed);
    uint8 internal constant LIVE = uint8(IPoppieEulerOracle.PriceState.Live);

    QuoteDataStub internal stub;
    AdapterHarness internal adapter;
    address internal constant BASE = address(0xBA5E);
    address internal constant USD = address(840);

    function setUp() public {
        stub = new QuoteDataStub();
        adapter = new AdapterHarness(IPoppieEulerOracle(address(stub)));
    }

    // -- Proof bodies ----------------------------------------------------------------------------

    /// @dev bid <= ask in every state, for every L, P and h.
    function _bidAskOrdering(uint8 s, uint128 L, uint128 P, uint16 h) internal view {
        (uint256 bid, uint256 ask) = adapter.bidAskBps(s, L, P, h);
        assert(bid <= ask);
    }

    /// @dev Live: bid == mid == ask == L (in the 10_000 basis).
    function _liveIsFlat(uint128 L, uint128 P, uint16 h) internal view {
        (uint256 bid, uint256 ask) = adapter.bidAskBps(LIVE, L, P, h);
        assert(bid == uint256(L) * BPS && ask == uint256(L) * BPS);
    }

    /// @dev Closed and Unconfirmed: the bid never exceeds L (1 - h), whichever way the pending price moved.
    function _bidCapped(uint8 s, uint128 L, uint128 P, uint16 h) internal view {
        if (s == LIVE) return;
        (uint256 bid,) = adapter.bidAskBps(s, L, P, h);
        assert(bid <= uint256(L) * (BPS - h));
    }

    /// @dev While L == 0 the bid is 0 in every state, so nothing can be borrowed before the first confirmation.
    function _zeroBidWithoutPrice(uint8 s, uint128 P, uint16 h) internal view {
        (uint256 bid,) = adapter.bidAskBps(s, 0, P, h);
        assert(bid == 0);
    }

    /// @dev The table of CONTRACT_SPEC.md 3.2, exactly.
    function _tableExact(uint8 s, uint128 L, uint128 P, uint16 h) internal view {
        (uint256 bid, uint256 ask) = adapter.bidAskBps(s, L, P, h);
        uint256 l = uint256(L) * BPS;
        uint256 hl = uint256(L) * (BPS - h);
        uint256 p = uint256(P) * BPS;
        if (s == LIVE) {
            assert(bid == l && ask == l);
        } else if (s == CLOSED) {
            assert(bid == hl && ask == l);
        } else {
            assert(bid == (p < hl ? p : hl));
            assert(ask == (p > l ? p : l));
        }
    }

    /// @dev The mid reverts in Closed and Unconfirmed, with the state's own error.
    function _midReverts(uint8 s, uint128 L, uint128 P, uint16 h, uint64 amount) internal {
        stub.set(IPoppieEulerOracle.PriceState(s), L, P, h, 18);
        try adapter.getQuote(amount, BASE, USD) returns (uint256) {
            assert(false);
        } catch (bytes memory err) {
            assert(
                bytes4(err)
                    == (s == CLOSED
                            ? IPoppieEulerAdapter.PriceUnavailable.selector
                            : IPoppieEulerAdapter.PriceUnconfirmed.selector)
            );
        }
    }

    /// @dev The one nonlinear step behind the ordering: scaling L by (BPS - h) never exceeds scaling it by BPS.
    function _haircutMonotone(uint128 L, uint16 h) internal pure {
        assert(uint256(L) * (BPS - h) <= uint256(L) * BPS);
    }

    // -- Halmos entry points ---------------------------------------------------------------------

    /// @dev 64-bit prices: the 128-bit version does not finish in the solver (256-bit nonlinear multiplication).
    /// The `testFuzz_` twin below covers the full 128-bit range.
    function check_bidAsk_ordering(uint8 s, uint64 L, uint64 P, uint16 h) public view {
        vm.assume(s <= 2 && h <= BPS);
        _bidAskOrdering(s, L, P, h);
    }

    function check_haircut_monotone64(uint64 L, uint16 h) public pure {
        vm.assume(h <= BPS);
        _haircutMonotone(L, h);
    }

    function check_live_isFlat(uint128 L, uint128 P, uint16 h) public view {
        vm.assume(h <= BPS);
        _liveIsFlat(L, P, h);
    }

    function check_bid_cappedOutsideLive(uint8 s, uint128 L, uint128 P, uint16 h) public view {
        vm.assume(s <= 2 && h <= BPS);
        _bidCapped(s, L, P, h);
    }

    function check_bid_zeroWithoutPrice(uint8 s, uint128 P, uint16 h) public view {
        vm.assume(s <= 2 && h <= BPS);
        _zeroBidWithoutPrice(s, P, h);
    }

    function check_table_exact(uint8 s, uint128 L, uint128 P, uint16 h) public view {
        vm.assume(s <= 2 && h <= BPS);
        _tableExact(s, L, P, h);
    }

    function check_mid_revertsWhenNotLive(uint8 s, uint128 L, uint128 P, uint16 h, uint64 amount) public {
        vm.assume(s <= 1 && h <= BPS);
        _midReverts(s, L, P, h, amount);
    }

    // -- Forge twins -----------------------------------------------------------------------------

    function testFuzz_bidAsk_ordering(uint8 s, uint128 L, uint128 P, uint16 h) public view {
        _bidAskOrdering(uint8(bound(s, 0, 2)), L, P, uint16(bound(h, 0, BPS)));
    }

    function testFuzz_live_isFlat(uint128 L, uint128 P, uint16 h) public view {
        _liveIsFlat(L, P, uint16(bound(h, 0, BPS)));
    }

    function testFuzz_bid_cappedOutsideLive(uint8 s, uint128 L, uint128 P, uint16 h) public view {
        _bidCapped(uint8(bound(s, 0, 2)), L, P, uint16(bound(h, 0, BPS)));
    }

    function testFuzz_bid_zeroWithoutPrice(uint8 s, uint128 P, uint16 h) public view {
        _zeroBidWithoutPrice(uint8(bound(s, 0, 2)), P, uint16(bound(h, 0, BPS)));
    }

    function testFuzz_table_exact(uint8 s, uint128 L, uint128 P, uint16 h) public view {
        _tableExact(uint8(bound(s, 0, 2)), L, P, uint16(bound(h, 0, BPS)));
    }

    function testFuzz_mid_revertsWhenNotLive(uint8 s, uint128 L, uint128 P, uint16 h, uint64 amount) public {
        _midReverts(uint8(bound(s, 0, 1)), L, P, uint16(bound(h, 0, BPS)), amount);
    }
}
