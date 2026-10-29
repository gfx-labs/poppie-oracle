// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ZeroAddress} from "../access/Errors.sol";
import {IPoppieEulerAdapter} from "../interfaces/IPoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../interfaces/IPoppieEulerOracle.sol";

/// @title PoppieEulerAdapter
/// @notice Euler `IPriceOracle` adapter over `PoppieEulerOracle`, three-state (CONTRACT_SPEC.md section 3.2,
/// V2_PLAN.md section 2). Immutable, no admin.
/// @dev Accepts `quote == address(840)` (USD) and a `base` the oracle lists; anything else reverts
/// `UnsupportedPair`. Prices are 18-decimal USD per whole token.
///
/// With `L` the last confirmed price, `P` the pending price and `h` the haircut of the base's price class:
///
/// | State       | getQuote (mid)           | bid                 | ask       |
/// | ----------- | ------------------------ | ------------------- | --------- |
/// | Live        | L                        | L                   | L         |
/// | Closed      | reverts PriceUnavailable | L * (1 - h)         | L         |
/// | Unconfirmed | reverts PriceUnconfirmed | min(P, L * (1 - h)) | max(P, L) |
///
/// All prices are carried scaled by 10_000 (so `1 - h` is exact in integers) and converted once at the end: the
/// mid and the bid round down, the ask rounds up. That keeps `bid <= mid <= ask` whenever the mid is defined, and
/// `bid <= ask` always. While `L == 0` the bid is 0.
contract PoppieEulerAdapter is IPoppieEulerAdapter {
    uint256 internal constant BPS = 10_000;

    string public constant override name = "PoppieEulerAdapter";

    /// @inheritdoc IPoppieEulerAdapter
    IPoppieEulerOracle public immutable override oracle;

    /// @inheritdoc IPoppieEulerAdapter
    address public constant override USD = address(840);

    /// @param oracle_ The `PoppieEulerOracle` to read. Must be non-zero (`ZeroAddress`, the shared error of
    /// `access/Errors.sol`; no interface change).
    constructor(IPoppieEulerOracle oracle_) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
    }

    /// @notice Mid price, used by EVK for liquidations. Reverts while the base is Closed or Unconfirmed.
    function getQuote(uint256 inAmount, address base, address quote) external view override returns (uint256) {
        IPoppieEulerOracle.QuoteData memory q = _quoteData(base, quote);
        if (q.state == IPoppieEulerOracle.PriceState.Closed) revert PriceUnavailable();
        if (q.state == IPoppieEulerOracle.PriceState.Unconfirmed) revert PriceUnconfirmed();
        return _convert(inAmount, uint256(q.lastPrice) * BPS, q.decimals, Math.Rounding.Floor);
    }

    /// @notice Bid (collateral valuation for borrowing power, rounds down) and ask (rounds up).
    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        override
        returns (uint256 bidOutAmount, uint256 askOutAmount)
    {
        IPoppieEulerOracle.QuoteData memory q = _quoteData(base, quote);
        (uint256 bid, uint256 ask) = _bidAskBps(q);
        bidOutAmount = _convert(inAmount, bid, q.decimals, Math.Rounding.Floor);
        askOutAmount = _convert(inAmount, ask, q.decimals, Math.Rounding.Ceil);
    }

    /// @dev Bid and ask prices in the 10_000-scaled basis (see the contract comment), per the table above.
    function _bidAskBps(IPoppieEulerOracle.QuoteData memory q) internal pure returns (uint256 bid, uint256 ask) {
        uint256 last = q.lastPrice;
        bid = last * BPS;
        ask = bid;
        if (q.state != IPoppieEulerOracle.PriceState.Live) {
            // Closed and Unconfirmed: the bid never rises above L * (1 - h).
            bid = last * (BPS - q.haircutBps);
            if (q.state == IPoppieEulerOracle.PriceState.Unconfirmed) {
                uint256 pending = uint256(q.pendingPrice) * BPS;
                if (pending < bid) bid = pending;
                if (pending > ask) ask = pending;
            }
        }
    }

    function _quoteData(address base, address quote) internal view returns (IPoppieEulerOracle.QuoteData memory q) {
        if (quote != USD) revert UnsupportedPair(base, quote);
        try oracle.getQuoteData(base) returns (IPoppieEulerOracle.QuoteData memory data) {
            q = data;
        } catch {
            // The oracle reverts `AssetNotListed` for a base it does not list.
            revert UnsupportedPair(base, quote);
        }
    }

    /// @dev `inAmount` base units at `priceBps` (18-decimal USD per whole token, times 10_000).
    function _convert(uint256 inAmount, uint256 priceBps, uint8 decimals, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(inAmount, priceBps, (10 ** decimals) * BPS, rounding);
    }
}
