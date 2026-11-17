// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IEulerRouterSubset {
    function governor() external view returns (address);
    function resolvedVaults(address vault) external view returns (address asset);
    function getConfiguredOracle(address base, address quote) external view returns (address);
    function govSetConfig(address base, address quote, address oracle) external;
    function govSetResolvedVault(address vault, bool set) external;
}
