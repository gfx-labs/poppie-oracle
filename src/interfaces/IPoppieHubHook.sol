// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

/// @dev Longest `K_GUARD` borrow pause per call (no cooldown between calls).
uint40 constant MAX_BORROW_PAUSE = 24 hours;
/// @dev Longest `MS_OPS` liquidation pause per call (calls can be chained).
uint40 constant MAX_LIQUIDATION_PAUSE = 6 hours;

/// @title IPoppieHubHook
/// @notice The single hook target for all hubs: fee hook and pause hook (CONTRACT_SPEC.md section 3.4).
/// @dev Hooked operations are `HUB_HOOKED_OPS` (see `hooks/HookOps.sol`): borrow, liquidate, flash loan and
/// the vault status check. EVK calls this contract with the original calldata plus the authenticated caller
/// (20 bytes) appended; the hook functions below are the selectors EVK forwards. A call from a vault that
/// is not a registered hub reverts `NotRegisteredHub`.
///
/// | Operation               | Behaviour                                                                          |
/// | ----------------------- | ---------------------------------------------------------------------------------- |
/// | OP_BORROW               | revert if paused; require receiver == fee router and amount != max; recordPending |
/// | OP_VAULT_STATUS_CHECK   | require router.pendingTotal(hub) == 0                                              |
/// | OP_FLASHLOAN            | always revert                                                                      |
/// | OP_LIQUIDATE            | revert only while a liquidation pause is active                                    |
///
/// Roles: `K_GUARD` (borrow pause), `MS_OPS` (liquidation pause), `DEFAULT_ADMIN_ROLE` (register hubs).
interface IPoppieHubHook is IHookTarget {
    // -- Events ---------------------------------------------------------------------------------

    event HubRegistered(address indexed hub);
    event BorrowsPaused(address indexed hub, uint40 until, address indexed by);
    event LiquidationsPaused(address indexed hub, uint40 until, address indexed by);

    // -- Errors ---------------------------------------------------------------------------------

    error ZeroAddress();
    error NotRegisteredHub(address vault);
    error HubAlreadyRegistered(address hub);
    error BorrowsArePaused(address hub, uint40 until);
    error LiquidationsArePaused(address hub, uint40 until);
    error FlashLoansDisabled();
    /// @dev Borrow receiver is not the fee router.
    error ReceiverNotFeeRouter(address receiver);
    /// @dev `borrow(type(uint256).max, ...)` is rejected.
    error MaxBorrowNotAllowed();
    /// @dev Status check ran while the router still holds pending funds.
    error PendingNotForwarded(address hub, uint256 pendingTotal);
    /// @dev `duration` is zero or above the cap for the pause type.
    error InvalidPauseDuration(uint40 duration, uint40 max);

    // -- Hook entry points (called by registered hubs, caller appended to calldata) --------------

    /// @dev OP_BORROW.
    function borrow(uint256 amount, address receiver) external;
    /// @dev OP_LIQUIDATE.
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    /// @dev OP_FLASHLOAN. Always reverts `FlashLoansDisabled`.
    function flashLoan(uint256 amount, bytes calldata data) external;
    /// @dev OP_VAULT_STATUS_CHECK. Return value is ignored by EVK.
    function checkVaultStatus() external returns (bytes4);

    // -- Governance -----------------------------------------------------------------------------

    /// @notice Register a hub. Role `DEFAULT_ADMIN_ROLE` (timelock).
    function registerHub(address hub) external;

    /// @notice Pause borrows on `hub` for `duration` seconds (<= `MAX_BORROW_PAUSE`). Role `K_GUARD`.
    /// No cooldown: it can pause again as soon as the pause expires.
    function pauseBorrows(address hub, uint40 duration) external;

    /// @notice Pause liquidations on `hub` for `duration` seconds (<= `MAX_LIQUIDATION_PAUSE`). Role `MS_OPS`.
    /// Calls can be chained back to back.
    function pauseLiquidations(address hub, uint40 duration) external;

    // -- Views ----------------------------------------------------------------------------------

    function isHub(address vault) external view returns (bool);
    function borrowPausedUntil(address hub) external view returns (uint40);
    function liquidationPausedUntil(address hub) external view returns (uint40);
    function feeRouter() external view returns (address);
    function evc() external view returns (address);
}
