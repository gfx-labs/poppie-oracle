// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";
import {IPoppieEulerOracle} from "./IPoppieEulerOracle.sol";

/// @title IPoppieEulerAdapter
/// @notice Euler `IPriceOracle` adapter, three-state (CONTRACT_SPEC.md section 3.2). Immutable, no admin.
/// @dev Accepts only `quote == address(840)` (USD) and a `base` that the oracle lists. Prices scale to 18
/// decimals against USD. Bid (`getQuotes` first value) rounds down, ask (second value) rounds up.
///
/// | State       | getQuote (mid)           | bid                 | ask           |
/// | ----------- | ------------------------ | ------------------- | ------------- |
/// | Live        | L                        | L                   | L             |
/// | Closed      | reverts PriceUnavailable | L * (1 - h)         | L             |
/// | Unconfirmed | reverts PriceUnconfirmed | min(P, L * (1 - h)) | max(P, L)     |
///
/// While `L == 0` the bid is 0.
interface IPoppieEulerAdapter is IPriceOracle {
    /// @notice Raised by `getQuote` while the base is Closed.
    error PriceUnavailable();
    /// @notice Raised by `getQuote` while the base is Unconfirmed.
    error PriceUnconfirmed();
    /// @notice `quote` is not USD, or `base` is not a token the oracle lists.
    error UnsupportedPair(address base, address quote);

    /// @notice The oracle this adapter reads. Immutable.
    function oracle() external view returns (IPoppieEulerOracle);

    /// @notice `address(840)`, the ISO 4217 code for USD, as used by Euler as a unit of account. Immutable.
    function USD() external view returns (address);
}
