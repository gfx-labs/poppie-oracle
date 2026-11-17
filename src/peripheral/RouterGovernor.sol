// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEulerRouterSubset} from "./interfaces/IEulerRouterSubset.sol";
import {IAdapterSubset} from "./interfaces/IAdapterSubset.sol";
import {IFactorySubset, IAssetSubset} from "./interfaces/IFactoryAndAssetSubset.sol";

/// @title RouterGovernor (P5)
/// @notice Holds the EulerRouter `governor` slot. Ops adds routes to the Poppie adapter and resolved
///         escrow vaults instantly, never changing or shadowing an existing entry. Anything else
///         (overwrites, deletions, fallback, `transferGovernance` exit) goes through the timelock.
contract RouterGovernor {
    IEulerRouterSubset public immutable router;
    IAdapterSubset public immutable adapter;
    address public immutable quote;
    IFactorySubset public immutable escrowFactory;
    address public immutable opsSafe;
    address public immutable timelock;

    error Unauthorized();
    error ZeroAddress();
    error BaseNotRegistered(address base);
    error RouteExists(address base);
    error IsResolvedVault(address vault);
    error NotFactoryVault(address vault);
    error AssetNotRouted(address vault, address asset);
    error CallFailed();

    event RouteAdded(address indexed base);
    event ResolvedVaultAdded(address indexed vault, address indexed asset);
    event Executed(bytes data);

    modifier only(address a) {
        if (msg.sender != a) revert Unauthorized();
        _;
    }

    constructor(
        IEulerRouterSubset router_,
        IAdapterSubset adapter_,
        IFactorySubset escrowFactory_,
        address opsSafe_,
        address timelock_
    ) {
        if (
            address(router_) == address(0) || address(adapter_) == address(0)
                || address(escrowFactory_) == address(0) || opsSafe_ == address(0) || timelock_ == address(0)
        ) revert ZeroAddress();
        router = router_;
        adapter = adapter_;
        quote = adapter_.unitOfAccount();
        escrowFactory = escrowFactory_;
        opsSafe = opsSafe_;
        timelock = timelock_;
    }

    function addRoute(address base) external only(opsSafe) {
        (bool registered,) = adapter.getBaseInfo(base);
        if (!registered) revert BaseNotRegistered(base);
        if (router.getConfiguredOracle(base, quote) != address(0)) revert RouteExists(base);
        if (router.resolvedVaults(base) != address(0)) revert IsResolvedVault(base);
        router.govSetConfig(base, quote, address(adapter));
        emit RouteAdded(base);
    }

    function addResolvedVault(address vault) external only(opsSafe) {
        if (router.resolvedVaults(vault) != address(0)) revert IsResolvedVault(vault);
        if (router.getConfiguredOracle(vault, quote) != address(0)) revert RouteExists(vault);
        if (!escrowFactory.isProxy(vault)) revert NotFactoryVault(vault);
        address asset = IAssetSubset(vault).asset();
        if (router.getConfiguredOracle(asset, quote) != address(adapter)) revert AssetNotRouted(vault, asset);
        router.govSetResolvedVault(vault, true);
        emit ResolvedVaultAdded(vault, asset);
    }

    /// @notice Raw router call by the timelock: overwrites, deletions, fallback, `transferGovernance`.
    function execute(bytes calldata data) external only(timelock) {
        (bool ok, bytes memory ret) = address(router).call(data);
        if (!ok) {
            if (ret.length == 0) revert CallFailed();
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit Executed(data);
    }
}
