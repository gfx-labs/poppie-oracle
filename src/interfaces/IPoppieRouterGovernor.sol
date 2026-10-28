// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoppieRouterGovernor
/// @notice The governor of the EulerRouter. All three add functions are add-only (CONTRACT_SPEC.md section 3.7).
/// @dev Roles: `MS_OPS` (the add functions), `DEFAULT_ADMIN_ROLE` = timelock (`setApprovedToken`, `execute`).
///
/// | Function                | Rule                                                                              |
/// | ----------------------- | --------------------------------------------------------------------------------- |
/// | addRoute(token)         | token approved; route (token, USD) unset; adapter is always PoppieEulerAdapter    |
/// | addWrapper(wrapper)     | from the wrapper factory, wraps an approved token, not registered; registers       |
/// |                         | wrapper -> token as a resolved vault                                              |
/// | addResolvedVault(escrow)| unset; non-upgradeable EVK factory proxy; no oracle, no unit of account; governor |
/// |                         | admin is the Poppie Governor; hook target is the escrow hook with ESCROW_HOOKED_OPS;|
/// |                         | asset() is an approved token or a registered wrapper                              |
interface IPoppieRouterGovernor {
    // -- Events ---------------------------------------------------------------------------------

    event ApprovedTokenSet(address indexed token, bool approved);
    event RouteAdded(address indexed token, address indexed adapter);
    event WrapperAdded(address indexed wrapper, address indexed token);
    event ResolvedVaultAdded(address indexed escrow, address indexed asset);
    event Executed(bytes data, bytes result);

    // -- Errors ---------------------------------------------------------------------------------

    error ZeroAddress();
    error TokenNotApproved(address token);
    error RouteAlreadySet(address token);
    error NotFactoryWrapper(address wrapper);
    error WrapperAlreadyRegistered(address wrapper);
    error ResolvedVaultAlreadySet(address vault);
    error NotFactoryProxy(address escrow);
    /// @dev The escrow is an upgradeable (beacon) proxy.
    error EscrowUpgradeable(address escrow);
    error EscrowHasOracle(address escrow);
    error EscrowHasUnitOfAccount(address escrow);
    /// @dev `governorAdmin()` is not the Poppie Governor.
    error EscrowWrongGovernor(address escrow, address governorAdmin);
    /// @dev Hook target or hooked operations differ from the expected `ESCROW_HOOKED_OPS` configuration.
    error EscrowWrongHookConfig(address escrow, address hookTarget, uint32 hookedOps);
    /// @dev `asset()` is neither an approved token nor a registered wrapper.
    error EscrowAssetNotAllowed(address escrow, address asset);
    error ExecuteFailed(bytes reason);

    // -- MS_OPS ---------------------------------------------------------------------------------

    function addRoute(address token) external;
    function addWrapper(address wrapper) external;
    function addResolvedVault(address escrow) external;

    // -- DEFAULT_ADMIN_ROLE (timelock) ----------------------------------------------------------

    /// @notice Approve or remove a token from the approved token list.
    function setApprovedToken(address token, bool approved) external;

    /// @notice Any other router change, including overwrites. Calls the EulerRouter with `data`.
    function execute(bytes calldata data) external returns (bytes memory result);

    // -- Views ----------------------------------------------------------------------------------

    function isApprovedToken(address token) external view returns (bool);
    /// @notice The EulerRouter this contract governs.
    function router() external view returns (address);
    /// @notice The `PoppieEulerAdapter` used for every route.
    function adapter() external view returns (address);
    function wrapperFactory() external view returns (address);
    /// @notice The EVK `GenericFactory` that escrow vaults must come from.
    function vaultFactory() external view returns (address);
    /// @notice The Euler GovernorAccessControl that must be `governorAdmin()` of every escrow vault.
    function poppieGovernor() external view returns (address);
    function escrowHook() external view returns (address);
}
