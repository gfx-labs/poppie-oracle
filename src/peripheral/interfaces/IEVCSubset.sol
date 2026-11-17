// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IEVCSubset {
    function getAccountOwner(address account) external view returns (address);
    function isControlCollateralInProgress() external view returns (bool);
}
