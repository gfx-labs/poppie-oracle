// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoppieWrapperFactory
/// @notice Creates `PoppieBalanceWrapper`s and keeps the wrapper registry (CONTRACT_SPEC.md section 3.9).
/// @dev The registry views are what `PoppieRouterGovernor`, `PoppieEscrowHook` and `PoppieRiskSteward` read.
/// One wrapper per token. Creation is callable by any address, because the router governor verifies what gets
/// registered. The dividend recipient (the reserve Safe) is changed only by `DEFAULT_ADMIN_ROLE` (timelock).
interface IPoppieWrapperFactory {
    event WrapperCreated(address indexed token, address indexed wrapper, address indexed creator, uint256 seedAmount);
    event DividendRecipientSet(address indexed previousRecipient, address indexed newRecipient);

    error ZeroAddress();
    error WrapperAlreadyExists(address token, address wrapper);
    /// @dev `seedAmount` is zero.
    error ZeroSeed();

    /// @notice Deploy the wrapper for `token`, pulling `seedAmount` (> 0, raw token units) from the caller as
    /// the seed deposit. The caller must have approved the factory. Seed shares are locked permanently.
    /// @dev No minimum beyond non-zero: the wrapper's virtual share offset already makes first-depositor
    /// inflation unprofitable, and wrappers are identical whoever creates them.
    function createWrapper(address token, uint256 seedAmount) external returns (address wrapper);

    /// @notice Change the dividend recipient. Role `DEFAULT_ADMIN_ROLE` (timelock).
    function setDividendRecipient(address newRecipient) external;

    // -- Registry views -------------------------------------------------------------------------

    /// @notice True for every wrapper this factory created.
    function isWrapper(address wrapper) external view returns (bool);
    /// @notice The wrapper for `token`, or the zero address.
    function wrapperOf(address token) external view returns (address);
    /// @notice Where `sweep` sends non-underlying tokens (the reserve Safe).
    function dividendRecipient() external view returns (address);
}
