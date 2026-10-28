// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoppieFeeRouter
/// @notice Collects the origination fee without operator rights (CONTRACT_SPEC.md section 3.3). Non-upgradeable.
/// @dev One EVC batch: `hub.borrow(amount, receiver = router)` -> hub hook calls `recordPending` ->
/// `router.forward(hub, to)` via `evc.call` for the same account -> hub hook status check requires
/// `pendingTotal(hub) == 0`. Pending state lives in transient storage only, so the router's token balance
/// never changes across a transaction. There is no treasury address: the fee goes to `hub.feeReceiver()`.
/// Roles: `MS_OPS` (fees, sweep).
interface IPoppieFeeRouter {
    // -- Events ---------------------------------------------------------------------------------

    event PendingRecorded(address indexed hub, address indexed account, uint256 amount);
    event Forwarded(
        address indexed hub, address indexed account, address indexed to, uint256 fee, uint256 net, address feeReceiver
    );
    event FeeBpsSet(address indexed hub, uint16 bps);
    event Swept(address indexed token, address indexed to, uint256 amount);

    // -- Errors ---------------------------------------------------------------------------------

    error ZeroAddress();
    /// @dev `recordPending` called by anything other than the hub hook.
    error OnlyHook();
    /// @dev `forward` not reached through the EVC.
    error NotCalledViaEVC();
    error NothingPending(address hub, address account);
    /// @dev `hub.feeReceiver()` is the zero address.
    error FeeReceiverNotSet(address hub);
    /// @dev `bps` above `MAX_FEE_BPS`.
    error FeeTooHigh(uint16 bps);

    // -- Hook-only ------------------------------------------------------------------------------

    /// @notice Add to transient `pending[hub][account]` and `pendingTotal[hub]`. Caller: `PoppieHubHook` only.
    function recordPending(address hub, address account, uint256 amount) external;

    // -- Account, via the EVC -------------------------------------------------------------------

    /// @notice Resolves the account with `evc.getCurrentOnBehalfOfAccount(address(0))`, requires `pending > 0`,
    /// sends `fee = ceil(pending * feeBps[hub] / 10_000)` to `hub.feeReceiver()` and `pending - fee` to `to`,
    /// then clears pending. Reverts if `hub.feeReceiver()` is zero. Must be called through the EVC.
    function forward(address hub, address to) external;

    // -- MS_OPS ---------------------------------------------------------------------------------

    /// @notice Set a hub's origination fee. Requires `bps <= MAX_FEE_BPS`.
    function setFeeBps(address hub, uint16 bps) external;

    /// @notice Recover tokens sent to the router by mistake.
    function sweep(address token, address to) external;

    // -- Views ----------------------------------------------------------------------------------

    /// @notice Hard cap on the fee: 100 bps.
    function MAX_FEE_BPS() external view returns (uint16);
    function feeBps(address hub) external view returns (uint16);
    /// @notice Pending amount within the current transaction.
    function pending(address hub, address account) external view returns (uint256);
    /// @notice Total pending for `hub` within the current transaction. Zero outside a batch.
    function pendingTotal(address hub) external view returns (uint256);
    function hook() external view returns (address);
    function evc() external view returns (address);
}
