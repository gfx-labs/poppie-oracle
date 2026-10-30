// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {MS_OPS} from "../access/Roles.sol";
import {IPoppieFeeRouter} from "../interfaces/IPoppieFeeRouter.sol";

/// @dev The two hub getters the router reads. Both are plain EVK views.
interface IFeeRouterHub {
    function asset() external view returns (address);
    function feeReceiver() external view returns (address);
}

/// @title PoppieFeeRouter
/// @notice Collects the origination fee without operator rights (CONTRACT_SPEC.md section 3.3, V2_PLAN.md
/// section 3). Non-upgradeable.
/// @dev Pending amounts live in transient storage (EIP-1153), keyed by a tag, the hub and the account. They
/// never outlive a transaction, so the router's token balance is the same before and after every transaction
/// (`sweep` aside, which only moves tokens sent by mistake).
///
/// Flow in one EVC batch: `hub.borrow(amount, router)` -> hub hook calls `recordPending` -> `forward(hub, to)`
/// through `evc.call` for the same account -> hub hook status check requires `pendingTotal(hub) == 0`.
///
/// - `forward` resolves the account from the EVC, so it can only ever clear that account's own pending amount.
/// - The fee goes to `hub.feeReceiver()`, read on every `forward`, so a receiver change applies from the next
///   call. There is no treasury address and no setter for one. A zero receiver reverts.
/// - `to` and the fee receiver must not be the router itself: either would leave tokens here and break the
///   balance invariant. `to == 0` is rejected with `ZeroAddress`; a receiver that is zero or the router reverts
///   `FeeReceiverNotSet`.
/// - Both `hook` and `evc` are immutable. The deploy script precomputes the CREATE address of the second
///   contract of the router/hook pair.
contract PoppieFeeRouter is IPoppieFeeRouter, PoppieAccessControl {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 100;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Domain tags for the transient slots, so a pending slot can never collide with a total slot.
    bytes32 private constant PENDING_TAG = keccak256("poppie.feerouter.pending");
    bytes32 private constant TOTAL_TAG = keccak256("poppie.feerouter.pendingTotal");

    address public immutable hook;
    address public immutable evc;

    mapping(address hub => uint16) public feeBps;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @param evc_ The Ethereum Vault Connector the hubs use.
    /// @param hook_ The `PoppieHubHook`, the only caller of `recordPending`.
    constructor(address initialAdmin, address evc_, address hook_) PoppieAccessControl(initialAdmin) {
        if (evc_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        evc = evc_;
        hook = hook_;
    }

    // -- Hook-only ------------------------------------------------------------------------------

    /// @inheritdoc IPoppieFeeRouter
    function recordPending(address hub, address account, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();

        bytes32 pendingSlot = _pendingSlot(hub, account);
        bytes32 totalSlot = _totalSlot(hub);
        _tstore(pendingSlot, _tload(pendingSlot) + amount);
        _tstore(totalSlot, _tload(totalSlot) + amount);

        emit PendingRecorded(hub, account, amount);
    }

    // -- Account, via the EVC -------------------------------------------------------------------

    /// @inheritdoc IPoppieFeeRouter
    function forward(address hub, address to) external {
        if (msg.sender != evc) revert NotCalledViaEVC();
        // With `address(0)` as the controller to check, the second return value is always false.
        (address account, bool controllerEnabled) = IEVC(evc).getCurrentOnBehalfOfAccount(address(0));
        assert(!controllerEnabled);

        bytes32 pendingSlot = _pendingSlot(hub, account);
        uint256 amount = _tload(pendingSlot);
        if (amount == 0) revert NothingPending(hub, account);
        if (to == address(0) || to == address(this)) revert ZeroAddress();

        address feeReceiver = IFeeRouterHub(hub).feeReceiver();
        if (feeReceiver == address(0) || feeReceiver == address(this)) revert FeeReceiverNotSet(hub);

        // `feeBps <= MAX_FEE_BPS`, so `fee <= amount`.
        uint256 fee = Math.mulDiv(amount, feeBps[hub], BPS_DENOMINATOR, Math.Rounding.Ceil);
        uint256 net = amount - fee;

        bytes32 totalSlot = _totalSlot(hub);
        _tstore(pendingSlot, 0);
        _tstore(totalSlot, _tload(totalSlot) - amount);

        IERC20 token = IERC20(IFeeRouterHub(hub).asset());
        if (fee != 0) token.safeTransfer(feeReceiver, fee);
        if (net != 0) token.safeTransfer(to, net);

        emit Forwarded(hub, account, to, fee, net, feeReceiver);
    }

    // -- MS_OPS ---------------------------------------------------------------------------------

    /// @inheritdoc IPoppieFeeRouter
    function setFeeBps(address hub, uint16 bps) external onlyRole(MS_OPS) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        feeBps[hub] = bps;
        emit FeeBpsSet(hub, bps);
    }

    /// @inheritdoc IPoppieFeeRouter
    /// @dev Sends the router's whole balance of `token`. Not meant to be called while a batch has pending funds.
    function sweep(address token, address to) external onlyRole(MS_OPS) {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // -- Views ----------------------------------------------------------------------------------

    /// @inheritdoc IPoppieFeeRouter
    function pending(address hub, address account) external view returns (uint256) {
        return _tload(_pendingSlot(hub, account));
    }

    /// @inheritdoc IPoppieFeeRouter
    function pendingTotal(address hub) external view returns (uint256) {
        return _tload(_totalSlot(hub));
    }

    // -- Transient storage ----------------------------------------------------------------------

    function _pendingSlot(address hub, address account) private pure returns (bytes32) {
        return keccak256(abi.encode(PENDING_TAG, hub, account));
    }

    function _totalSlot(address hub) private pure returns (bytes32) {
        return keccak256(abi.encode(TOTAL_TAG, hub));
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
