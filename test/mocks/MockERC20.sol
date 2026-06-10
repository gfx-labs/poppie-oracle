// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MockERC20
/// @notice Minimal mock ERC20 with configurable decimals for testing.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    /// @notice Test helper to mutate decimals after deployment (e.g. to verify an
    ///         adapter uses cached decimals rather than a live decimals() call).
    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }
}
