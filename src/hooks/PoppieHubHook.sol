// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {IVault} from "ethereum-vault-connector/interfaces/IVault.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {MS_OPS, K_GUARD} from "../access/Roles.sol";
import {IPoppieFeeRouter} from "../interfaces/IPoppieFeeRouter.sol";
import {IPoppieHubHook, MAX_BORROW_PAUSE, MAX_LIQUIDATION_PAUSE} from "../interfaces/IPoppieHubHook.sol";

/// @title PoppieHubHook
/// @notice The single hook target for all hubs: fee hook and pause hook (CONTRACT_SPEC.md section 3.4,
/// V2_PLAN.md section 3).
/// @dev EVK calls a hook target with the original calldata plus the authenticated caller (20 bytes) appended, so
/// `msg.sender` is the hub and the caller is the last 20 bytes of `msg.data`. For the vault status check the
/// appended caller is the EVC. Every entry point rejects a `msg.sender` that is not a registered hub.
///
/// A pause is active while `block.timestamp < pausedUntil`. A pause call sets the expiry to `now + duration`
/// (it replaces any earlier expiry); there is no cooldown state, so a pause can be set again as soon as one
/// expires, and liquidation pauses can be chained.
///
/// Both `feeRouter` and `evc` are immutable. The deploy script precomputes the CREATE address of the second
/// contract of the router/hook pair; there is no setter.
contract PoppieHubHook is IPoppieHubHook, PoppieAccessControl {
    address public immutable feeRouter;
    address public immutable evc;

    mapping(address vault => bool) public isHub;
    mapping(address hub => uint40) public borrowPausedUntil;
    mapping(address hub => uint40) public liquidationPausedUntil;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @param evc_ The Ethereum Vault Connector the hubs use.
    /// @param feeRouter_ The `PoppieFeeRouter`, whose `hook()` is this contract.
    constructor(address initialAdmin, address evc_, address feeRouter_) PoppieAccessControl(initialAdmin) {
        if (evc_ == address(0) || feeRouter_ == address(0)) revert ZeroAddress();
        evc = evc_;
        feeRouter = feeRouter_;
    }

    modifier onlyHub() {
        if (!isHub[msg.sender]) revert NotRegisteredHub(msg.sender);
        _;
    }

    /// @notice Magic value EVK checks when the hook target is installed with `setHookConfig`.
    function isHookTarget() external pure returns (bytes4) {
        return IHookTarget.isHookTarget.selector;
    }

    // -- Hook entry points ----------------------------------------------------------------------

    /// @inheritdoc IPoppieHubHook
    function borrow(uint256 amount, address receiver) external onlyHub {
        uint40 until = borrowPausedUntil[msg.sender];
        if (block.timestamp < until) revert BorrowsArePaused(msg.sender, until);
        if (receiver != feeRouter) revert ReceiverNotFeeRouter(receiver);
        if (amount == type(uint256).max) revert MaxBorrowNotAllowed();

        IPoppieFeeRouter(feeRouter).recordPending(msg.sender, _caller(), amount);
    }

    /// @inheritdoc IPoppieHubHook
    function liquidate(address, address, uint256, uint256) external onlyHub {
        uint40 until = liquidationPausedUntil[msg.sender];
        if (block.timestamp < until) revert LiquidationsArePaused(msg.sender, until);
    }

    /// @inheritdoc IPoppieHubHook
    function flashLoan(uint256, bytes calldata) external onlyHub {
        revert FlashLoansDisabled();
    }

    /// @inheritdoc IPoppieHubHook
    function checkVaultStatus() external onlyHub returns (bytes4) {
        uint256 total = IPoppieFeeRouter(feeRouter).pendingTotal(msg.sender);
        if (total != 0) revert PendingNotForwarded(msg.sender, total);
        return IVault.checkVaultStatus.selector;
    }

    // -- Governance -----------------------------------------------------------------------------

    /// @inheritdoc IPoppieHubHook
    function registerHub(address hub) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hub == address(0)) revert ZeroAddress();
        if (isHub[hub]) revert HubAlreadyRegistered(hub);
        isHub[hub] = true;
        emit HubRegistered(hub);
    }

    /// @inheritdoc IPoppieHubHook
    function pauseBorrows(address[] calldata hubs, uint40 duration) external onlyRole(K_GUARD) {
        _checkDuration(duration, MAX_BORROW_PAUSE);
        uint40 until = uint40(block.timestamp) + duration;
        for (uint256 i; i < hubs.length; ++i) {
            address hub = hubs[i];
            if (!isHub[hub]) revert NotRegisteredHub(hub);
            borrowPausedUntil[hub] = until;
            emit BorrowsPaused(hub, until, msg.sender);
        }
    }

    /// @inheritdoc IPoppieHubHook
    function unpauseBorrows(address[] calldata hubs) external onlyRole(MS_OPS) {
        for (uint256 i; i < hubs.length; ++i) {
            address hub = hubs[i];
            if (block.timestamp >= borrowPausedUntil[hub]) continue;
            borrowPausedUntil[hub] = 0;
            emit BorrowsUnpaused(hub, msg.sender);
        }
    }

    /// @inheritdoc IPoppieHubHook
    function pauseLiquidations(address[] calldata hubs, uint40 duration) external onlyRole(MS_OPS) {
        _checkDuration(duration, MAX_LIQUIDATION_PAUSE);
        uint40 until = uint40(block.timestamp) + duration;
        for (uint256 i; i < hubs.length; ++i) {
            address hub = hubs[i];
            if (!isHub[hub]) revert NotRegisteredHub(hub);
            liquidationPausedUntil[hub] = until;
            emit LiquidationsPaused(hub, until, msg.sender);
        }
    }

    /// @inheritdoc IPoppieHubHook
    function unpauseLiquidations(address[] calldata hubs) external onlyRole(MS_OPS) {
        for (uint256 i; i < hubs.length; ++i) {
            address hub = hubs[i];
            if (block.timestamp >= liquidationPausedUntil[hub]) continue;
            liquidationPausedUntil[hub] = 0;
            emit LiquidationsUnpaused(hub, msg.sender);
        }
    }

    // -- Internal -------------------------------------------------------------------------------

    function _checkDuration(uint40 duration, uint40 max) private pure {
        if (duration == 0 || duration > max) revert InvalidPauseDuration(duration, max);
    }

    /// @dev The authenticated caller EVK appends to the original calldata.
    function _caller() private pure returns (address) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    }
}
