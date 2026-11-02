// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title MockXStock
/// @notice Test model of an xStocks (Backed) EVM token. Internal share units
///         never change; `balanceOf = shares * multiplier`. Multiplier updates
///         are scheduled with an activation timestamp and take effect for
///         everyone at once, as described at
///         https://docs.xstocks.fi/developers/multipliers.md.
///         The `multiplierUpdates` getters match the interface Euler's
///         ChainlinkInfrequentXStocksOracle reads
///         (lib/euler-price-oracle/src/adapter/chainlink/ChainlinkInfrequentXStocksOracle.sol:6-12).
/// @dev    Rounding is modelled, not copied from Backed: amounts are converted
///         to share units rounding down, so `transfer(x)` can credit `x - 1`.
contract MockXStock {
    uint256 internal constant WAD = 1e18;

    string public name = "Mock xStock";
    string public symbol = "MOCKx";
    uint8 public constant decimals = 18;

    struct Update {
        uint256 previousMultiplier;
        uint256 newMultiplier;
        uint256 activationTime;
    }

    Update[] internal _updates;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ── multiplier ──────────────────────────────────────────────────────

    function multiplierUpdatesLength() external view returns (uint256) {
        return _updates.length;
    }

    function multiplierUpdates(uint256 i) external view returns (uint256, uint256, uint256) {
        Update storage u = _updates[i];
        return (u.previousMultiplier, u.newMultiplier, u.activationTime);
    }

    /// @notice Schedule a multiplier change. Updates must be in time order.
    function scheduleMultiplier(uint256 newMultiplier, uint256 activationTime) external {
        uint256 n = _updates.length;
        uint256 prev = n == 0 ? WAD : _updates[n - 1].newMultiplier;
        if (n != 0) require(activationTime > _updates[n - 1].activationTime, "order");
        _updates.push(Update(prev, newMultiplier, activationTime));
    }

    function getCurrentMultiplier() public view returns (uint256) {
        for (uint256 i = _updates.length; i > 0; --i) {
            if (_updates[i - 1].activationTime <= block.timestamp) return _updates[i - 1].newMultiplier;
        }
        return _updates.length == 0 ? WAD : _updates[0].previousMultiplier;
    }

    // ── ERC-20 ──────────────────────────────────────────────────────────

    function balanceOf(address a) public view returns (uint256) {
        return sharesOf[a] * getCurrentMultiplier() / WAD;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares * getCurrentMultiplier() / WAD;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        uint256 s = amount * WAD / getCurrentMultiplier();
        sharesOf[to] += s;
        totalShares += s;
        emit Transfer(address(0), to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 s = amount * WAD / getCurrentMultiplier();
        require(sharesOf[from] >= s, "balance");
        sharesOf[from] -= s;
        sharesOf[to] += s;
        emit Transfer(from, to, amount);
    }
}
