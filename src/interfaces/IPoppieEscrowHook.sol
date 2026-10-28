// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

/// @dev Longest `K_GUARD` deposit pause per call (no cooldown between calls).
uint40 constant MAX_DEPOSIT_PAUSE = 24 hours;

/// @title IPoppieEscrowHook
/// @notice The single hook target for all escrow vaults (CONTRACT_SPEC.md section 3.5).
/// @dev Hooked operations are `ESCROW_HOOKED_OPS` (see `hooks/HookOps.sol`): deposit, mint, skim, transfer.
/// EVK calls this contract with the original calldata plus the authenticated caller (20 bytes) appended.
///
/// Each hooked operation reverts when the oracle state of the vault's underlying token is Closed, or when
/// deposits are paused for that vault. The hook first resolves the vault's `asset()`: if it is a wrapper
/// (`factory.isWrapper`), the oracle is asked about the wrapper's underlying token, which is the only thing
/// the oracle lists. `transfer` is allowed while `evc.isControlCollateralInProgress()`, so liquidations can
/// seize collateral during a deposit pause. Withdraw and redeem are never hooked.
/// Role: `K_GUARD` (deposit pause).
interface IPoppieEscrowHook is IHookTarget {
    // -- Events ---------------------------------------------------------------------------------

    event DepositsPaused(address indexed vault, uint40 until, address indexed by);

    // -- Errors ---------------------------------------------------------------------------------

    error ZeroAddress();
    /// @dev Oracle state of the underlying token is Closed.
    error AssetClosed(address vault, address underlying);
    error DepositsArePaused(address vault, uint40 until);
    /// @dev `duration` is zero or above `MAX_DEPOSIT_PAUSE`.
    error InvalidPauseDuration(uint40 duration, uint40 max);

    // -- Hook entry points (called by escrow vaults, caller appended to calldata) ----------------

    /// @dev OP_DEPOSIT.
    function deposit(uint256 amount, address receiver) external;
    /// @dev OP_MINT.
    function mint(uint256 amount, address receiver) external;
    /// @dev OP_SKIM.
    function skim(uint256 amount, address receiver) external;
    /// @dev OP_TRANSFER. Matches EVK's `transfer` signature; the return value is ignored by EVK.
    function transfer(address to, uint256 amount) external returns (bool);

    // -- Governance -----------------------------------------------------------------------------

    /// @notice Pause deposits into `vault` for `duration` seconds (<= `MAX_DEPOSIT_PAUSE`). Role `K_GUARD`.
    /// No cooldown: it can pause again as soon as the pause expires.
    function pauseDeposits(address vault, uint40 duration) external;

    // -- Views ----------------------------------------------------------------------------------

    function depositsPausedUntil(address vault) external view returns (uint40);
    /// @notice The `PoppieEulerOracle`.
    function oracle() external view returns (address);
    /// @notice The `PoppieWrapperFactory`.
    function wrapperFactory() external view returns (address);
    function evc() external view returns (address);
}
