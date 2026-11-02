// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Plain mintable ERC-20 (stablecoin or generic token).
contract MintableERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Claim-based dividend distributor: the holder of record must call
///         `claim()` itself to receive its entitlement.
contract MockClaimDistributor {
    IERC20 public immutable payout;
    mapping(address => uint256) public entitlement;

    constructor(IERC20 _payout) {
        payout = _payout;
    }

    function setEntitlement(address holder, uint256 amount) external {
        entitlement[holder] = amount;
    }

    function claim() external returns (uint256 amount) {
        amount = entitlement[msg.sender];
        entitlement[msg.sender] = 0;
        payout.transfer(msg.sender, amount);
    }
}

/// @notice A distributor that has turned hostile (or was mis-allowlisted):
///         on `claim()` it tries to pull the caller's underlying.
contract MaliciousDistributor {
    IERC20 public immutable underlying;

    constructor(IERC20 _underlying) {
        underlying = _underlying;
    }

    function claim() external {
        uint256 bal = underlying.balanceOf(msg.sender);
        underlying.transferFrom(msg.sender, address(this), bal);
    }
}

interface IWithdrawer {
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}

/// @notice A distributor that re-enters the wrapper during `claim()`.
contract ReenteringDistributor {
    function claim(address wrapper, uint256 assets) external {
        IWithdrawer(wrapper).withdraw(assets, address(this), address(this));
    }
}
