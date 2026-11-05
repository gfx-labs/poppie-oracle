// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockRealityToken
/// @notice Test model of a Reality rToken (Bitget's issuer, Arbitrum One).
///         Two balance models, both seen on-chain:
///         - Legacy (beacon implementations before 2026-10-17 03:11 UTC):
///           `balanceOf = raw * 1e18 / rebaseIndex`. A split lowered the index
///           (rAPH 2:1: 1.0 -> 0.5), so every holder's `balanceOf` changed.
///         - Current (implementation 0x752C8073033046898aF127b3C78210E0D6e6C764):
///           ERC-8056. `balanceOf` is static; `uiMultiplier()` carries splits
///           and applies at once (`newUIMultiplier == uiMultiplier`,
///           `effectiveAt == 0` on every token read 2026-11-05).
///         `migrate()` reproduces the 2026-10-17 upgrade: the index resets to
///         1e18 (balances move by the split factor), then the multiplier is
///         set to the cumulative ratio.
///         Dividends are not modelled in the token: Reality pays cash (USDT0)
///         and stock (rTokens) separately to the depositor, traced by Merkl
///         through supported protocols, and withholds them for unsupported
///         ones. Nothing arrives at an escrow.
/// @dev    No access control. On the real token: actions are created by an
///         EOA on a registry (0xd01f8aa9...) and executed by the 3-of-5
///         configurer Safe with the matching ratio (hash-checked, once only,
///         no check against the effective time). Freeze and unpause: Safe.
///         Pause: operator EOA. The source is unverified; behaviour is from
///         simulated calls on an Arbitrum fork.
contract MockRealityToken is ERC20 {
    uint256 internal constant WAD = 1e18;

    bool public legacy = true;
    uint256 public rebaseIndex = WAD;
    uint256 public uiMultiplier = WAD;

    bool public paused;
    bool public isDelisted;
    mapping(address => bool) public isFrozen;

    mapping(address => uint256) internal _raw;
    uint256 internal _rawSupply;

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    constructor() ERC20("Mock (Reality Tokenized)", "rMOCK") {}

    // ── balances ────────────────────────────────────────────────────────

    function balanceOf(address a) public view override returns (uint256) {
        return legacy ? _raw[a] * WAD / rebaseIndex : _raw[a];
    }

    function totalSupply() public view override returns (uint256) {
        return legacy ? _rawSupply * WAD / rebaseIndex : _rawSupply;
    }

    function newUIMultiplier() external view returns (uint256) {
        return uiMultiplier;
    }

    function effectiveAt() external pure returns (uint256) {
        return 0;
    }

    function balanceOfUI(address a) external view returns (uint256) {
        return balanceOf(a) * uiMultiplier / WAD;
    }

    function _toRaw(uint256 amount) internal view returns (uint256) {
        return legacy ? amount * rebaseIndex / WAD : amount;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) require(!paused, "EnforcedPause");
        require(!isFrozen[from] && !isFrozen[to], "AccountIsFrozen");
        uint256 r = _toRaw(value);
        if (from == address(0)) _rawSupply += r;
        else _raw[from] -= r;
        if (to == address(0)) _rawSupply -= r;
        else _raw[to] += r;
        emit Transfer(from, to, value);
    }

    // ── corporate actions ───────────────────────────────────────────────

    /// @notice Execute a split of `fromShares -> toShares` (bps, as in the
    ///         registry: 10000 -> 40000 is 4:1). Legacy: rebase. Current:
    ///         multiplier, applied at once.
    function executeRebase(uint256 fromShares, uint256 toShares) external {
        if (legacy) {
            rebaseIndex = rebaseIndex * fromShares / toShares;
        } else {
            uint256 old = uiMultiplier;
            uiMultiplier = old * toShares / fromShares;
            emit UIMultiplierUpdated(old, uiMultiplier, block.timestamp);
        }
    }

    /// @notice The 2026-10-17 upgrade: balances revert to raw (index 1e18),
    ///         then the cumulative ratio is set as the multiplier.
    function migrate() external {
        require(legacy, "done");
        uint256 cumulative = WAD * WAD / rebaseIndex; // shares per raw unit
        legacy = false;
        rebaseIndex = WAD; // balanceOf is now the raw (pre-split) count
        uiMultiplier = cumulative;
        emit UIMultiplierUpdated(WAD, cumulative, block.timestamp);
    }

    // ── issuer controls ─────────────────────────────────────────────────

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }

    function setFrozen(address a, bool f) external {
        isFrozen[a] = f;
    }

    /// @notice On-chain, `delist()` did not stop transfers in a fork test.
    function delist() external {
        isDelisted = true;
    }
}
