// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.24;

/// @title IPriceOracle
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice Common PriceOracle interface (ERC-7726).
///
/// @dev Vendored from:
///      https://github.com/euler-xyz/euler-price-oracle/blob/abfbfc9/src/interfaces/IPriceOracle.sol
///      Commit: abfbfc9 (euler-xyz/euler-price-oracle)
interface IPriceOracle {
    /// @notice Get the name of the oracle.
    function name() external view returns (string memory);

    /// @notice One-sided price: How much quote token you would get for inAmount
    ///         of base token, assuming no price spread.
    /// @param inAmount The amount of `base` to convert.
    /// @param base The token that is being priced.
    /// @param quote The token that is the unit of account.
    /// @return outAmount The amount of `quote` equivalent to `inAmount` of `base`.
    function getQuote(uint256 inAmount, address base, address quote)
        external
        view
        returns (uint256 outAmount);

    /// @notice Two-sided price: How much quote token you would get/spend for
    ///         selling/buying inAmount of base token.
    /// @param inAmount The amount of `base` to convert.
    /// @param base The token that is being priced.
    /// @param quote The token that is the unit of account.
    /// @return bidOutAmount The amount of `quote` for selling `inAmount` of `base`.
    /// @return askOutAmount The amount of `quote` for buying `inAmount` of `base`.
    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        returns (uint256 bidOutAmount, uint256 askOutAmount);
}
