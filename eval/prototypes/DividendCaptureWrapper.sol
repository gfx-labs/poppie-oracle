// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ─────────────────────────────────────────────────────────────────────────
// TEST-ONLY PROTOTYPE. NOT AUDITED. NOT FOR DEPLOYMENT.
// Exists to check that the "small additional contract" in
// docs/evaluation/Contracts.md (DIV-1) works with the unmodified v1 oracle and
// adapter and with EulerRouter. A production version needs its own spec,
// review and audit.
// ─────────────────────────────────────────────────────────────────────────

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DividendCaptureWrapper
/// @notice Unmodified OZ ERC4626 (decimalsOffset = 0) over an equity token,
///         plus two functions so the protocol, as holder of record, can
///         collect cash dividends:
///         - `sweep(token)`: anyone; sends any token except the underlying to
///           the immutable `reserve`.
///         - `claim(target, data)`: operator only; calls an allowlisted
///           distributor, then checks the underlying balance did not drop.
///         Dividends never change share value; they are protocol revenue.
contract DividendCaptureWrapper is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable reserve;
    address public immutable operator;
    mapping(address => bool) public isDistributor;

    error OnlyOperator();
    error CannotSweepUnderlying();
    error DistributorNotAllowed(address target);
    error ClaimFailed(bytes reason);
    error UnderlyingDecreased(uint256 before, uint256 afterBal);

    event DistributorSet(address indexed target, bool allowed);
    event Claimed(address indexed target);
    event Swept(address indexed token, uint256 amount);

    constructor(IERC20 underlying, string memory n, string memory s, address _reserve, address _operator)
        ERC20(n, s)
        ERC4626(underlying)
    {
        require(_reserve != address(0) && _operator != address(0), "zero");
        reserve = _reserve;
        operator = _operator;
    }

    function setDistributor(address target, bool allowed) external {
        if (msg.sender != operator) revert OnlyOperator();
        // the underlying and the wrapper itself can never be call targets
        if (target == asset() || target == address(this)) revert DistributorNotAllowed(target);
        isDistributor[target] = allowed;
        emit DistributorSet(target, allowed);
    }

    function claim(address target, bytes calldata data) external nonReentrant {
        if (msg.sender != operator) revert OnlyOperator();
        if (!isDistributor[target]) revert DistributorNotAllowed(target);
        uint256 before = IERC20(asset()).balanceOf(address(this));
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert ClaimFailed(ret);
        uint256 afterBal = IERC20(asset()).balanceOf(address(this));
        if (afterBal < before) revert UnderlyingDecreased(before, afterBal);
        emit Claimed(target);
    }

    function sweep(address token) external nonReentrant returns (uint256 amount) {
        if (token == asset()) revert CannotSweepUnderlying();
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(reserve, amount);
        emit Swept(token, amount);
    }

    // Block re-entry into share accounting while a claim is in flight.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }
}
