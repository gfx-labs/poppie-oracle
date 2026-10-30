// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {IPoppieWrapperFactory} from "../interfaces/IPoppieWrapperFactory.sol";
import {PoppieBalanceWrapper} from "./PoppieBalanceWrapper.sol";

/// @title PoppieWrapperFactory
/// @notice Creates `PoppieBalanceWrapper`s and keeps the wrapper registry (CONTRACT_SPEC.md section 3.9,
/// V2_PLAN.md section 2a).
/// @dev - `createWrapper` is callable by any address: the router governor verifies what gets registered
///        (`isWrapper`, approved token), and a wrapper is identical whoever creates it.
///      - One wrapper per token. Wrappers are deployed with CREATE2, salted by the token, so the address is
///        deterministic.
///      - The seed (`seedAmount > 0`, raw token units) is pulled from the caller and deposited with this
///        factory as the receiver. The factory has no function that moves wrapper shares, so the seed shares
///        are locked permanently.
///      - `dividendRecipient` (the reserve Safe) is set by `DEFAULT_ADMIN_ROLE` (the timelock, i.e. MS_ADMIN).
///        It is the only admin function; wrappers themselves have none.
contract PoppieWrapperFactory is IPoppieWrapperFactory, PoppieAccessControl, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IPoppieWrapperFactory
    mapping(address wrapper => bool) public isWrapper;
    /// @inheritdoc IPoppieWrapperFactory
    mapping(address token => address) public wrapperOf;
    /// @inheritdoc IPoppieWrapperFactory
    address public dividendRecipient;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @param dividendRecipient_ Where wrappers sweep non-underlying tokens (the reserve Safe). Non-zero.
    constructor(address initialAdmin, address dividendRecipient_) PoppieAccessControl(initialAdmin) {
        _setDividendRecipient(dividendRecipient_);
    }

    /// @inheritdoc IPoppieWrapperFactory
    function createWrapper(address token, uint256 seedAmount) external nonReentrant returns (address wrapper) {
        if (token == address(0)) revert ZeroAddress();
        if (seedAmount == 0) revert ZeroSeed();
        address existing = wrapperOf[token];
        if (existing != address(0)) revert WrapperAlreadyExists(token, existing);

        wrapper = address(new PoppieBalanceWrapper{salt: bytes32(uint256(uint160(token)))}(IERC20(token)));
        isWrapper[wrapper] = true;
        wrapperOf[token] = wrapper;

        // Seed: caller -> factory -> wrapper. The factory keeps the shares and can never move them. Only the
        // amount the factory actually received is forwarded (a rebasing token may deliver a wei less).
        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), seedAmount);
        uint256 balanceAfter = asset.balanceOf(address(this));
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        asset.forceApprove(wrapper, received);
        // The seed share count is not needed: the shares stay with the factory, and `deposit` reverts
        // `ZeroSharesMinted` when nothing would be minted.
        // slither-disable-next-line unused-return
        PoppieBalanceWrapper(wrapper).deposit(received, address(this));
        asset.forceApprove(wrapper, 0);

        emit WrapperCreated(token, wrapper, msg.sender, seedAmount);
    }

    /// @inheritdoc IPoppieWrapperFactory
    function setDividendRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDividendRecipient(newRecipient);
    }

    function _setDividendRecipient(address newRecipient) private {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit DividendRecipientSet(dividendRecipient, newRecipient);
        dividendRecipient = newRecipient;
    }
}
