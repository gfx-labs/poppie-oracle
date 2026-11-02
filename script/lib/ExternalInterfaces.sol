// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// Minimal interfaces for Euler contracts used at their canonical addresses but not compiled here. Euler Earn is
// built with solc 0.8.26 (the repo pins 0.8.24), so its sources are not imported; these mirror the subset of
// `euler-earn/src/interfaces/IEulerEarn{,Factory}.sol` and evk-periphery's kink IRM factory that the scripts call.

interface IEulerEarnMinimal {
    function submitCap(IERC4626 id, uint256 newSupplyCap) external;
    function acceptCap(IERC4626 id) external;
    function setSupplyQueue(IERC4626[] calldata newSupplyQueue) external;
    function submitTimelock(uint256 newTimelock) external;
    function setCurator(address newCurator) external;
    function setIsAllocator(address newAllocator, bool newIsAllocator) external;
    function transferOwnership(address newOwner) external;
    function curator() external view returns (address);
    function isAllocator(address target) external view returns (bool);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function supplyQueueLength() external view returns (uint256);
}

interface IEulerEarnFactoryMinimal {
    function createEulerEarn(
        address initialOwner,
        uint256 initialTimelock,
        address asset,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (IEulerEarnMinimal);
    function isStrategyAllowed(address id) external view returns (bool);
    function supportedPerspective() external view returns (address);
}

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink) external returns (address);
}
