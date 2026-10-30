// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {MS_OPS, K_GUARD} from "../access/Roles.sol";
import {IPoppieEscrowHook, MAX_DEPOSIT_PAUSE} from "../interfaces/IPoppieEscrowHook.sol";
import {IPoppieEulerOracle} from "../interfaces/IPoppieEulerOracle.sol";
import {IPoppieWrapperFactory} from "../interfaces/IPoppieWrapperFactory.sol";

/// @title PoppieEscrowHook
/// @notice The single hook target for all escrow vaults (CONTRACT_SPEC.md section 3.5, V2_PLAN.md section 4).
/// @dev EVK calls a hook target with the original calldata plus the authenticated caller (20 bytes) appended, so
/// `msg.sender` is the escrow vault. Every hooked operation (deposit, mint, skim and the three `OP_TRANSFER`
/// entry points) runs the same check on `msg.sender`:
///   1. transfers only: allowed outright while `evc.isControlCollateralInProgress()` (liquidation seizure);
///   2. revert while a deposit pause is active for the vault;
///   3. resolve `vault.asset()` to the underlying token (through `factory.isWrapper`) and revert if the oracle
///      state of that token is Closed. An unlisted token makes the oracle revert `AssetNotListed`, which also
///      blocks the operation (fail closed).
/// Withdraw and redeem are never hooked, so exits are never blocked.
///
/// A pause is active while `block.timestamp < depositsPausedUntil`. A pause call sets the expiry to
/// `now + duration` (it replaces any earlier expiry). There is no cooldown state: `K_GUARD` can pause again as soon
/// as a pause expires (OPEN_QUESTIONS.md Q8); the control is `MS_OPS` revoking the key, plus off-chain alerts.
///
/// `evc`, `oracle` and `wrapperFactory` are immutable; there is no setter.
contract PoppieEscrowHook is IPoppieEscrowHook, PoppieAccessControl {
    address public immutable evc;
    address public immutable oracle;
    address public immutable wrapperFactory;

    mapping(address vault => uint40) public depositsPausedUntil;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @param evc_ The Ethereum Vault Connector the escrow vaults use.
    /// @param oracle_ The `PoppieEulerOracle`.
    /// @param wrapperFactory_ The `PoppieWrapperFactory`.
    constructor(address initialAdmin, address evc_, address oracle_, address wrapperFactory_)
        PoppieAccessControl(initialAdmin)
    {
        if (evc_ == address(0) || oracle_ == address(0) || wrapperFactory_ == address(0)) revert ZeroAddress();
        evc = evc_;
        oracle = oracle_;
        wrapperFactory = wrapperFactory_;
    }

    /// @notice Magic value EVK checks when the hook target is installed with `setHookConfig`.
    function isHookTarget() external pure returns (bytes4) {
        return IHookTarget.isHookTarget.selector;
    }

    // -- Hook entry points ----------------------------------------------------------------------

    /// @inheritdoc IPoppieEscrowHook
    function deposit(uint256, address) external view {
        _checkDeposit(msg.sender);
    }

    /// @inheritdoc IPoppieEscrowHook
    function mint(uint256, address) external view {
        _checkDeposit(msg.sender);
    }

    /// @inheritdoc IPoppieEscrowHook
    function skim(uint256, address) external view {
        _checkDeposit(msg.sender);
    }

    /// @inheritdoc IPoppieEscrowHook
    function transfer(address, uint256) external view returns (bool) {
        _checkTransfer(msg.sender);
        return true;
    }

    /// @inheritdoc IPoppieEscrowHook
    function transferFrom(address, address, uint256) external view returns (bool) {
        _checkTransfer(msg.sender);
        return true;
    }

    /// @inheritdoc IPoppieEscrowHook
    function transferFromMax(address, address) external view returns (bool) {
        _checkTransfer(msg.sender);
        return true;
    }

    // -- Governance -----------------------------------------------------------------------------

    /// @inheritdoc IPoppieEscrowHook
    function pauseDeposits(address[] calldata vaults, uint40 duration) external onlyRole(K_GUARD) {
        if (duration == 0 || duration > MAX_DEPOSIT_PAUSE) revert InvalidPauseDuration(duration, MAX_DEPOSIT_PAUSE);
        uint40 until = uint40(block.timestamp) + duration;
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            depositsPausedUntil[vault] = until;
            emit DepositsPaused(vault, until, msg.sender);
        }
    }

    /// @inheritdoc IPoppieEscrowHook
    function unpauseDeposits(address[] calldata vaults) external onlyRole(MS_OPS) {
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            if (block.timestamp >= depositsPausedUntil[vault]) continue;
            depositsPausedUntil[vault] = 0;
            emit DepositsUnpaused(vault, msg.sender);
        }
    }

    // -- Internal -------------------------------------------------------------------------------

    /// @dev A liquidation seizes collateral with `transfer` inside `evc.controlCollateral`; let it through.
    function _checkTransfer(address vault) private view {
        if (IEVC(evc).isControlCollateralInProgress()) return;
        _checkDeposit(vault);
    }

    function _checkDeposit(address vault) private view {
        uint40 until = depositsPausedUntil[vault];
        if (block.timestamp < until) revert DepositsArePaused(vault, until);

        address underlying = _underlying(vault);
        if (IPoppieEulerOracle(oracle).state(underlying) == IPoppieEulerOracle.PriceState.Closed) {
            revert AssetClosed(vault, underlying);
        }
    }

    /// @dev The vault's `asset()`, or the wrapper's `asset()` if the vault holds a factory wrapper. EVK's
    /// `asset()` is `reentrantOK`, so it can be read from inside the hook.
    function _underlying(address vault) private view returns (address token) {
        token = IERC4626(vault).asset();
        if (IPoppieWrapperFactory(wrapperFactory).isWrapper(token)) token = IERC4626(token).asset();
    }
}
