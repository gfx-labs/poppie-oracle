// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {MS_OPS} from "../access/Roles.sol";
import {ESCROW_HOOKED_OPS} from "../hooks/HookOps.sol";
import {IPoppieRouterGovernor} from "../interfaces/IPoppieRouterGovernor.sol";
import {IPoppieWrapperFactory} from "../interfaces/IPoppieWrapperFactory.sol";

/// @title PoppieRouterGovernor
/// @notice The governor of the EulerRouter (CONTRACT_SPEC.md section 3.7, V2_PLAN.md section 5).
/// @dev - `MS_OPS` lists instantly through three add-only functions. None of them can overwrite an existing price
///        route or resolved vault, so a listing can never replace a price source:
///        - `addRoute(token)`: (token, USD) -> `PoppieEulerAdapter`, for approved tokens only.
///        - `addWrapper(wrapper)`: wrapper -> token, for factory wrappers of approved tokens only.
///        - `addResolvedVault(escrow)`: escrow -> asset, for correctly configured escrow vaults only.
///      - `DEFAULT_ADMIN_ROLE` (the timelock, i.e. MS_ADMIN) keeps the approved token list and can make any other
///        router change, including overwrites and governance transfer, through `execute`.
///      - The escrow checks make the deployer-key stage of the listing flow trustless: whatever the deployer
///        created, only a non-upgradeable EVK proxy from the canonical factory, with no oracle and no unit of
///        account (so nothing can be borrowed from it), governed by the Poppie Governor and hooked by the escrow
///        hook, can be priced by the router.
///      Every dependency address is immutable.
contract PoppieRouterGovernor is IPoppieRouterGovernor, PoppieAccessControl {
    /// @dev ISO 4217 code for USD, the quote of every route.
    address internal constant USD = address(840);

    /// @inheritdoc IPoppieRouterGovernor
    address public immutable router;
    /// @inheritdoc IPoppieRouterGovernor
    address public immutable adapter;
    /// @inheritdoc IPoppieRouterGovernor
    address public immutable wrapperFactory;
    /// @inheritdoc IPoppieRouterGovernor
    address public immutable vaultFactory;
    /// @inheritdoc IPoppieRouterGovernor
    address public immutable poppieGovernor;
    /// @inheritdoc IPoppieRouterGovernor
    address public immutable escrowHook;

    /// @inheritdoc IPoppieRouterGovernor
    mapping(address token => bool) public isApprovedToken;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @param router_ The EulerRouter. This contract must be made its governor after deployment.
    /// @param adapter_ The `PoppieEulerAdapter` every route points to.
    /// @param wrapperFactory_ The `PoppieWrapperFactory`.
    /// @param vaultFactory_ The EVK `GenericFactory` escrow vaults must come from.
    /// @param poppieGovernor_ The Euler GovernorAccessControl that must govern every escrow vault.
    /// @param escrowHook_ The `PoppieEscrowHook` every escrow vault must use as hook target.
    constructor(
        address initialAdmin,
        address router_,
        address adapter_,
        address wrapperFactory_,
        address vaultFactory_,
        address poppieGovernor_,
        address escrowHook_
    ) PoppieAccessControl(initialAdmin) {
        if (
            router_ == address(0) || adapter_ == address(0) || wrapperFactory_ == address(0)
                || vaultFactory_ == address(0) || poppieGovernor_ == address(0) || escrowHook_ == address(0)
        ) revert ZeroAddress();
        router = router_;
        adapter = adapter_;
        wrapperFactory = wrapperFactory_;
        vaultFactory = vaultFactory_;
        poppieGovernor = poppieGovernor_;
        escrowHook = escrowHook_;
    }

    // -- MS_OPS ---------------------------------------------------------------------------------

    /// @inheritdoc IPoppieRouterGovernor
    function addRoute(address token) external onlyRole(MS_OPS) {
        if (!isApprovedToken[token]) revert TokenNotApproved(token);
        if (EulerRouter(router).getConfiguredOracle(token, USD) != address(0)) revert RouteAlreadySet(token);

        emit RouteAdded(token, adapter);
        EulerRouter(router).govSetConfig(token, USD, adapter);
    }

    /// @inheritdoc IPoppieRouterGovernor
    function addWrapper(address wrapper) external onlyRole(MS_OPS) {
        // The factory check comes first, so only factory-deployed (trusted) code is called afterwards.
        if (!IPoppieWrapperFactory(wrapperFactory).isWrapper(wrapper)) revert NotFactoryWrapper(wrapper);
        if (EulerRouter(router).resolvedVaults(wrapper) != address(0)) revert WrapperAlreadyRegistered(wrapper);
        address token = IERC4626(wrapper).asset();
        if (!isApprovedToken[token]) revert TokenNotApproved(token);

        emit WrapperAdded(wrapper, token);
        EulerRouter(router).govSetResolvedVault(wrapper, true);
    }

    /// @inheritdoc IPoppieRouterGovernor
    function addResolvedVault(address escrow) external onlyRole(MS_OPS) {
        if (EulerRouter(router).resolvedVaults(escrow) != address(0)) revert ResolvedVaultAlreadySet(escrow);

        // Factory checks first, so only EVK code is called afterwards.
        GenericFactory factory = GenericFactory(vaultFactory);
        if (!factory.isProxy(escrow)) revert NotFactoryProxy(escrow);
        if (factory.getProxyConfig(escrow).upgradeable) revert EscrowUpgradeable(escrow);

        IEVault vault = IEVault(escrow);
        if (vault.oracle() != address(0)) revert EscrowHasOracle(escrow);
        if (vault.unitOfAccount() != address(0)) revert EscrowHasUnitOfAccount(escrow);
        address governorAdmin = vault.governorAdmin();
        if (governorAdmin != poppieGovernor) revert EscrowWrongGovernor(escrow, governorAdmin);
        (address hookTarget, uint32 hookedOps) = vault.hookConfig();
        if (hookTarget != escrowHook || hookedOps != ESCROW_HOOKED_OPS) {
            revert EscrowWrongHookConfig(escrow, hookTarget, hookedOps);
        }

        address asset = vault.asset();
        if (!_isAllowedEscrowAsset(asset)) revert EscrowAssetNotAllowed(escrow, asset);

        emit ResolvedVaultAdded(escrow, asset);
        EulerRouter(router).govSetResolvedVault(escrow, true);
    }

    // -- DEFAULT_ADMIN_ROLE (timelock) ----------------------------------------------------------

    /// @inheritdoc IPoppieRouterGovernor
    function setApprovedToken(address token, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isApprovedToken[token] = approved;
        emit ApprovedTokenSet(token, approved);
    }

    /// @inheritdoc IPoppieRouterGovernor
    function execute(bytes calldata data) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes memory result) {
        bool success;
        // The router is a fixed, trusted contract; the call is the timelock's own router change.
        // slither-disable-next-line low-level-calls
        (success, result) = router.call(data);
        if (!success) revert ExecuteFailed(result);
        // The event carries the call's result, so it can only be emitted after the call (to the trusted router).
        // slither-disable-next-line reentrancy-events
        emit Executed(data, result);
    }

    // -- Internal -------------------------------------------------------------------------------

    /// @dev An escrow's asset is allowed if it is an approved token, or a factory wrapper already registered in
    /// the router (through `addWrapper`), which in turn implies its token was approved at registration.
    function _isAllowedEscrowAsset(address asset) private view returns (bool) {
        if (isApprovedToken[asset]) return true;
        return IPoppieWrapperFactory(wrapperFactory).isWrapper(asset)
            && EulerRouter(router).resolvedVaults(asset) != address(0);
    }
}
