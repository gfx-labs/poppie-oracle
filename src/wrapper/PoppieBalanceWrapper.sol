// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoppieBalanceWrapper} from "../interfaces/IPoppieBalanceWrapper.sol";
import {IPoppieWrapperFactory} from "../interfaces/IPoppieWrapperFactory.sol";

/// @title PoppieBalanceWrapper
/// @notice Immutable ERC-4626-style wrapper for a balance-changing or dividend-paying token (CONTRACT_SPEC.md
/// section 3.9, V2_PLAN.md section 2a). One per token, deployed by `PoppieWrapperFactory`.
/// @dev - `totalAssets()` is the wrapper's own `balanceOf(asset)`. Shares only change on deposit, mint,
///        withdraw and redeem, so a rebase (positive or negative) or a donation moves the value of every share
///        pro rata. There is no skim and no admin.
///      - Deposits and mints credit shares from the balance actually received (balance after minus balance
///        before), priced against the balance before the transfer. A short transfer can only reduce the
///        depositor's own shares, never dilute other holders.
///      - First-depositor inflation is prevented by the factory's seed deposit (its shares are held by the
///        factory, which has no way to move them) and by OpenZeppelin's virtual share offset
///        (`DECIMALS_OFFSET`).
///      - Rounding always favours the wrapper: deposit floors shares, mint ceils assets, withdraw ceils shares,
///        redeem floors assets (OpenZeppelin ERC-4626).
///      - `sweep(token)` sends any token other than the underlying to the factory's `dividendRecipient()`. It
///        also checks that the underlying balance did not drop, which covers tokens with a second entry point.
contract PoppieBalanceWrapper is IPoppieBalanceWrapper, ERC4626, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Virtual share offset: 10**6 virtual shares per virtual asset unit. Share decimals are the
    /// underlying token's decimals plus this offset.
    uint8 private constant DECIMALS_OFFSET = 6;

    /// @inheritdoc IPoppieBalanceWrapper
    address public immutable factory;

    /// @param asset_ The wrapped token. The deployer (`msg.sender`) is recorded as the factory.
    constructor(IERC20 asset_) ERC20(_wrappedName(address(asset_)), _wrappedSymbol(address(asset_))) ERC4626(asset_) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        factory = msg.sender;
    }

    // -- Deposits -------------------------------------------------------------------------------

    /// @notice Deposit `assets`; shares are minted for the amount actually received.
    /// @return shares The shares minted (rounded down). Reverts `ZeroSharesMinted` when that is zero.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        shares = _pullAndMint(assets, receiver, type(uint256).max);
    }

    /// @notice Mint up to `shares`, pulling `previewMint(shares)` (rounded up). Shares are minted for the amount
    /// actually received, capped at `shares`; for a token that transfers exactly, that is exactly `shares`.
    /// @return assets The assets pulled from the caller.
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        _pullAndMint(assets, receiver, shares);
    }

    // -- Withdrawals (OpenZeppelin logic, guarded) ----------------------------------------------

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // -- Sweep ----------------------------------------------------------------------------------

    /// @inheritdoc IPoppieBalanceWrapper
    function sweep(address token) external nonReentrant returns (uint256 amount) {
        address underlying = asset();
        if (token == underlying) revert CannotSweepUnderlying();
        address recipient = IPoppieWrapperFactory(factory).dividendRecipient();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 underlyingBefore = IERC20(underlying).balanceOf(address(this));
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(recipient, amount);
        // A token with a second entry point onto the underlying's balances must not be able to move it.
        if (IERC20(underlying).balanceOf(address(this)) < underlyingBefore) revert CannotSweepUnderlying();

        emit Swept(token, recipient, amount);
    }

    // -- Internal -------------------------------------------------------------------------------

    /// @dev Pulls `assets` from the caller and mints `min(cap, shares for the amount received)` to `receiver`,
    /// priced against the balance and supply before the transfer (the same formula as `previewDeposit`).
    function _pullAndMint(uint256 assets, address receiver, uint256 cap) private returns (uint256 shares) {
        IERC20 token = IERC20(asset());
        uint256 supplyBefore = totalSupply();
        uint256 balanceBefore = token.balanceOf(address(this));

        address caller = _msgSender();
        token.safeTransferFrom(caller, address(this), assets);

        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

        shares = Math.mulDiv(received, supplyBefore + 10 ** _decimalsOffset(), balanceBefore + 1, Math.Rounding.Floor);
        if (shares > cap) shares = cap;
        // Intended exact check: a deposit worth less than one share must revert rather than mint nothing. A
        // donation can only make this revert for the depositor, never mint shares that are not backed.
        // slither-disable-next-line incorrect-equality
        if (shares == 0) revert ZeroSharesMinted();

        _mint(receiver, shares);
        emit Deposit(caller, receiver, received, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _wrappedName(address token) private view returns (string memory) {
        try IERC20Metadata(token).name() returns (string memory n) {
            return string.concat("Poppie Wrapped ", n);
        } catch {
            return "Poppie Wrapped Token";
        }
    }

    function _wrappedSymbol(address token) private view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return string.concat("pw", s);
        } catch {
            return "pwTOKEN";
        }
    }
}
