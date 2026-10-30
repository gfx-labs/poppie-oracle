// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Multiplier token (issuer mechanism `multiplier`): balances never change; a corporate action updates a
/// published multiplier instead (one token represents `multiplier / 1e18` underlying shares). Not wrapped: the
/// off-chain pricer folds the multiplier into the pushed price.
contract MockMultiplierToken is MockERC20 {
    uint256 public multiplier = 1e18;

    event MultiplierUpdated(uint256 previous, uint256 current);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    /// @notice Set the multiplier (WAD). 2e18 after a 2-for-1 split.
    function setMultiplier(uint256 newMultiplier) external {
        emit MultiplierUpdated(multiplier, newMultiplier);
        multiplier = newMultiplier;
    }
}
