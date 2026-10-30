// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Balance-changing token (issuer mechanism `balance-changing`, e.g. xStocks, Reality on splits).
/// Holders own internal shares; `balanceOf = shares * multiplier / 1e18`, so `rebase` changes every balance pro
/// rata without a transfer (a split, a reverse split, a dividend paid in kind).
/// @dev Like stETH, a transfer moves `amount * 1e18 / multiplier` shares rounded down, so the recipient can be
/// credited up to a wei less than `amount` (and the sender debited up to a wei less) while the multiplier is not
/// 1e18.
contract MockRebasingToken is IERC20 {
    uint256 internal constant WAD = 1e18;

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    /// @notice Balance per internal share, WAD.
    uint256 public multiplier = WAD;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    // -- Test controls --------------------------------------------------------------------------

    /// @notice Set the balance multiplier (WAD). 2e18 is a 2-for-1 split, 0.5e18 a 1-for-2 reverse split.
    function rebase(uint256 newMultiplier) external {
        require(newMultiplier != 0, "zero multiplier");
        multiplier = newMultiplier;
    }

    /// @notice Multiply every balance by `num / den`.
    function rebaseBy(uint256 num, uint256 den) external {
        uint256 m = multiplier * num / den;
        require(m != 0, "zero multiplier");
        multiplier = m;
    }

    function mint(address to, uint256 amount) external {
        uint256 s = _toShares(amount, true);
        sharesOf[to] += s;
        totalShares += s;
        emit Transfer(address(0), to, amount);
    }

    // -- ERC20 ----------------------------------------------------------------------------------

    function balanceOf(address account) public view returns (uint256) {
        return sharesOf[account] * multiplier / WAD;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares * multiplier / WAD;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf(from) >= amount, "balance");
        uint256 s = _toShares(amount, false);
        // Never move more shares than the sender holds (rounding at the edge).
        if (s > sharesOf[from]) s = sharesOf[from];
        sharesOf[from] -= s;
        sharesOf[to] += s;
        emit Transfer(from, to, amount);
    }

    function _toShares(uint256 amount, bool roundUp) internal view returns (uint256) {
        uint256 s = amount * WAD / multiplier;
        if (roundUp && s * multiplier < amount * WAD) s += 1;
        return s;
    }
}
