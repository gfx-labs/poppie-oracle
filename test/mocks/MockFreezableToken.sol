// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Token whose issuer can freeze addresses (xStocks / Ondo-style admin power): a frozen address can neither
/// send nor receive. Used for the issuer-freeze scenario (OPEN_QUESTIONS Q11: assert the on-chain symptom only).
contract MockFreezableToken is MockERC20 {
    mapping(address => bool) public frozen;

    error AccountFrozen(address account);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function freeze(address account, bool isFrozen) external {
        frozen[account] = isFrozen;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert AccountFrozen(from);
        if (frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
