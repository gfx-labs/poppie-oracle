// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockRobinhoodStockToken
/// @notice Test model of a Robinhood Stock Token (Robinhood Chain, chain 4663).
///         ERC-8056 "Scaled UI Amount": `balanceOf` and `totalSupply` are raw
///         and never change on a corporate action; `uiMultiplier()` is the
///         shares-per-token ratio (1e18 = 1.0) and is applied only in the
///         `*UI` views. Function names and the two `updateMultiplier`
///         overloads match the deployed implementation
///         (0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2, selectors read on-chain
///         2026-11-04). The scheduled overload's "not in the past" check is
///         the revert string observed on-chain.
/// @dev    Access control is omitted: any caller can update, pause, block or
///         burn. The real token checks roles held on a shared registry. The
///         `adminBurn` and `burn` behaviour (burn from any holder, no
///         allowance) matches simulated calls on the deployed token.
contract MockRobinhoodStockToken is ERC20 {
    uint256 internal constant WAD = 1e18;

    uint256 internal _uiMultiplier = WAD;
    uint256 internal _newUIMultiplier = WAD;
    uint256 internal _effectiveAt;

    bool public tokenPaused;
    bool public oraclePaused;
    mapping(address => bool) public isBlocked;

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    constructor() ERC20(unicode"Mock • Robinhood Token", "MOCK") {}

    // ── ERC-8056 ────────────────────────────────────────────────────────

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0xa60bf13d || id == 0x4bd27648 || id == 0xd890fd71;
    }

    function uiMultiplier() public view returns (uint256) {
        return block.timestamp >= _effectiveAt ? _newUIMultiplier : _uiMultiplier;
    }

    function newUIMultiplier() external view returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() external view returns (uint256) {
        return _effectiveAt;
    }

    function balanceOfUI(address a) external view returns (uint256) {
        return balanceOf(a) * uiMultiplier() / WAD;
    }

    function totalSupplyUI() external view returns (uint256) {
        return totalSupply() * uiMultiplier() / WAD;
    }

    /// @notice Instant update (the deployed token's `updateMultiplier(uint256)`).
    function updateMultiplier(uint256 m) external {
        updateMultiplier(m, block.timestamp);
    }

    /// @notice Scheduled update. Replaces any pending update.
    function updateMultiplier(uint256 m, uint256 at) public {
        require(at >= block.timestamp, "Effective time must not be in the past");
        uint256 old = uiMultiplier();
        _uiMultiplier = old;
        _newUIMultiplier = m;
        _effectiveAt = at;
        emit UIMultiplierUpdated(old, m, at);
    }

    // ── issuer controls ─────────────────────────────────────────────────

    function pauseOracle() external {
        oraclePaused = true;
    }

    function unpauseOracle() external {
        oraclePaused = false;
    }

    function pause() external {
        tokenPaused = true;
    }

    function unpause() external {
        tokenPaused = false;
    }

    function setBlocked(address a, bool b) external {
        isBlocked[a] = b;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns from any holder without an allowance.
    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(!tokenPaused, "paused");
            require(!isBlocked[from] && !isBlocked[to] && !isBlocked[msg.sender], "blocked");
        }
        super._update(from, to, value);
    }
}
