// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Chainalysis on-chain sanctions oracle.
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}
