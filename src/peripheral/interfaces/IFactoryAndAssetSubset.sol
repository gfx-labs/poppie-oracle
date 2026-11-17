// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev EVK GenericFactory subset (A30 m, unverified).
interface IFactorySubset {
    function isProxy(address proxy) external view returns (bool);
}

interface IAssetSubset {
    function asset() external view returns (address);
}
