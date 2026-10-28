// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IPoppieBalanceWrapper
/// @notice Immutable ERC-4626-style wrapper for a balance-changing or dividend-paying token
/// (CONTRACT_SPEC.md section 3.9). One per token, created by `PoppieWrapperFactory`.
/// @dev - Share count never changes on its own. `convertToAssets` follows the wrapper's own balance of the
///        token, so positive and negative rebases are shared pro rata.
///      - Deposits mint shares from the balance actually received.
///      - A seed deposit at creation plus a virtual share offset prevent first-depositor inflation. Seed shares
///        are locked permanently.
///      - No skim: tokens donated to the wrapper raise the value of every share.
///      - No admin function apart from the permissionless `sweep`.
///      `asset()` is the wrapped token (the only token the oracle lists).
interface IPoppieBalanceWrapper is IERC4626 {
    event Swept(address indexed token, address indexed recipient, uint256 amount);

    error ZeroAddress();
    /// @dev `sweep(asset())` is not allowed.
    error CannotSweepUnderlying();
    /// @dev Nothing was received on deposit.
    error ZeroSharesMinted();

    /// @notice Permissionless. Sends the whole balance of `token` (anything but `asset()`) to
    /// `factory().dividendRecipient()`. This is how dividends paid in stablecoins reach the reserve.
    /// @return amount The amount sent.
    function sweep(address token) external returns (uint256 amount);

    /// @notice The `PoppieWrapperFactory` that created this wrapper (holds the dividend recipient).
    function factory() external view returns (address);
}
