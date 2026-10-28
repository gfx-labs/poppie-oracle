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
    /// @dev `seedAmount` is below `minSeedAmount()`.
    error SeedTooLow(uint256 seedAmount, uint256 minSeedAmount);

    /// @notice Deploy the wrapper for `token`, pulling `seedAmount` from the caller as the seed deposit.
    /// The caller must have approved the factory. Seed shares are locked permanently.
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
    /// @notice Minimum seed deposit, in raw units of the wrapped token.
    function minSeedAmount() external view returns (uint256);
}
