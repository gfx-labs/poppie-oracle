// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IAdapterSubset {
    function unitOfAccount() external view returns (address);
    function getBaseInfo(address base) external view returns (bool registered, uint8 decimals);
}
