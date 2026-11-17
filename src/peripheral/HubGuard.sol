// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVaultHook, EVKOps} from "./interfaces/IEVaultHook.sol";
import {IEVCSubset} from "./interfaces/IEVCSubset.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";

/// @title HubGuard (P1)
/// @notice EVK hook target for hubs: borrow rate limit, origination fee, guardian pause,
///         sanctions/denylist screening, flash-loan switch.
/// @dev Hook calls carry the authenticated caller in the last 20 bytes of calldata; `msg.sender` is the hub.
///      Repay and liquidation must never be blocked: those ops are never hooked, unknown selectors hit an
///      empty `fallback`, and `checkVaultStatus` returns first thing when the batch did not borrow.
///      Per-batch state lives in plain storage, cleared at the status check (shanghai: no TSTORE).
contract HubGuard {
    uint8 public constant FLASH_OFF = 0;
    uint8 public constant FLASH_ON = 1;

    struct Cfg {
        bool configured;
        uint8 flashMode;
        uint16 feeBps;
        uint32 window;
        uint40 pausedUntil;
        uint40 windowStart;
        uint128 limit;
        address feeReceiver;
        uint256 used;
    }

    struct Batch {
        bool borrowed;
        uint256 before;
        uint256 owed;
        uint256 paid;
    }

    IEVCSubset public immutable evc;
    ISanctionsList public immutable sanctions;
    uint256 public immutable MAX_FEE_BPS;
    uint256 public immutable maxPauseDuration;

    address public owner;
    address public guardian;
    address public denylister;

    mapping(address => bool) public denied;
    mapping(address => Cfg) public cfg;
    mapping(address => Batch) public batch;
    /// @dev Optional per-account debt cap (A19); 0 = off. Accounts that borrowed in the batch are
    ///      checked at the status check.
    mapping(address => uint256) public debtCap;
    mapping(address => address[]) internal _batchAccounts;

    error NotHub();
    error Paused();
    error Blocked(address account);
    error AllCash();
    error FlashDisabled();
    error LimitExceeded();
    error FeeShort();
    error StatusCheckNotHooked();
    error Unauthorized();
    error ZeroAddress();
    error InvalidConfig();
    error DebtCapExceeded(address account);

    event HubSet(address indexed hub, uint128 limit, uint32 window, uint16 feeBps, address feeReceiver, uint8 flashMode);
    event HubPaused(address indexed hub, uint40 until);
    event HubUnpaused(address indexed hub);
    event Denied(address indexed account);
    event Undenied(address indexed account);
    event RoleSet(bytes32 indexed role, address indexed account);
    event BorrowsCounted(address indexed hub, uint256 net, uint256 used);
    event DebtCapSet(address indexed hub, uint256 cap);

    modifier only(address a) {
        if (msg.sender != a) revert Unauthorized();
        _;
    }

    constructor(
        IEVCSubset evc_,
        ISanctionsList sanctions_,
        uint256 maxFeeBps_,
        uint256 maxPauseDuration_,
        address owner_,
        address guardian_,
        address denylister_
    ) {
        if (address(evc_) == address(0) || address(sanctions_) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (maxFeeBps_ > 10_000 || maxPauseDuration_ > type(uint32).max) revert InvalidConfig();
        evc = evc_;
        sanctions = sanctions_;
        MAX_FEE_BPS = maxFeeBps_;
        maxPauseDuration = maxPauseDuration_;
        _setRole("owner", owner_);
        _setRole("guardian", guardian_);
        _setRole("denylister", denylister_);
    }

    // ── Hooks ───────────────────────────────────────────────────────────

    function isHookTarget() external pure returns (bytes4) {
        return this.isHookTarget.selector;
    }

    function borrow(uint256 amount, address receiver) external {
        Cfg storage c = _active();
        if (amount == type(uint256).max) revert AllCash();
        (, uint32 ops) = IEVaultHook(msg.sender).hookConfig();
        if (ops & EVKOps.OP_VAULT_STATUS_CHECK == 0) revert StatusCheckNotHooked();
        address account = _caller();
        _screen(_ownerOf(account));
        _screen(receiver);
        if (debtCap[msg.sender] != 0) _batchAccounts[msg.sender].push(account);

        Batch storage b = batch[msg.sender];
        if (!b.borrowed) {
            b.borrowed = true;
            b.before = IEVaultHook(msg.sender).totalBorrows();
        }
        if (c.feeBps != 0) {
            if (receiver == c.feeReceiver) b.paid += amount;
            else b.owed += (amount * c.feeBps + 9_999) / 10_000;
        }
    }

    function flashLoan(uint256, bytes calldata) external view {
        Cfg storage c = _active();
        if (c.flashMode != FLASH_ON) revert FlashDisabled();
    }

    function deposit(uint256, address receiver) external view {
        _screenInflow(receiver);
    }

    function mint(uint256, address receiver) external view {
        _screenInflow(receiver);
    }

    function skim(uint256, address receiver) external view {
        _screenInflow(receiver);
    }

    function checkVaultStatus() external {
        Batch storage b = batch[msg.sender];
        if (!b.borrowed) return; // must stay first: runs on repay/liquidation batches too

        Cfg storage c = cfg[msg.sender];
        uint256 tb = IEVaultHook(msg.sender).totalBorrows();
        uint256 net = tb > b.before ? tb - b.before : 0;
        if (block.timestamp >= uint256(c.windowStart) + c.window) {
            c.windowStart = uint40(block.timestamp);
            c.used = 0;
        }
        uint256 used = c.used + net;
        if (used > c.limit) revert LimitExceeded();
        if (b.paid < b.owed) revert FeeShort();
        c.used = used;
        delete batch[msg.sender];

        address[] storage accts = _batchAccounts[msg.sender];
        uint256 cap = debtCap[msg.sender];
        for (uint256 i; i < accts.length; ++i) {
            if (cap != 0 && IEVaultHook(msg.sender).debtOf(accts[i]) > cap) revert DebtCapExceeded(accts[i]);
        }
        delete _batchAccounts[msg.sender];
        emit BorrowsCounted(msg.sender, net, used);
    }

    /// @dev A mis-set hook bit must never block an operation (Rule 1).
    fallback() external {}

    // ── Owner (MS_OPS) ──────────────────────────────────────────────────

    function setHub(address hub, uint128 limit, uint32 window, uint16 feeBps, address feeReceiver, uint8 flashMode)
        external
        only(owner)
    {
        if (hub == address(0)) revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS || flashMode > FLASH_ON || (feeBps != 0 && feeReceiver == address(0))) {
            revert InvalidConfig();
        }
        Cfg storage c = cfg[hub];
        c.configured = true;
        c.limit = limit;
        c.window = window;
        c.feeBps = feeBps;
        c.feeReceiver = feeReceiver;
        c.flashMode = flashMode;
        emit HubSet(hub, limit, window, feeBps, feeReceiver, flashMode);
    }

    function setDebtCap(address hub, uint256 cap) external only(owner) {
        debtCap[hub] = cap;
        emit DebtCapSet(hub, cap);
    }

    function unpause(address hub) external only(owner) {
        cfg[hub].pausedUntil = 0;
        emit HubUnpaused(hub);
    }

    function removeDenied(address a) external only(owner) {
        denied[a] = false;
        emit Undenied(a);
    }

    function setOwner(address a) external only(owner) {
        if (a == address(0)) revert ZeroAddress();
        _setRole("owner", a);
    }

    function setGuardian(address a) external only(owner) {
        _setRole("guardian", a);
    }

    function setDenylister(address a) external only(owner) {
        _setRole("denylister", a);
    }

    // ── Hot keys: tighten only ──────────────────────────────────────────

    /// @notice Pause borrows and flash loans; can only extend an existing pause.
    function pause(address hub, uint256 duration) external only(guardian) {
        if (duration > maxPauseDuration) revert InvalidConfig();
        // forge-lint: disable-next-line(unsafe-typecast) duration <= type(uint32).max (constructor): fits uint40
        uint40 until = uint40(block.timestamp + duration);
        Cfg storage c = cfg[hub];
        if (until > c.pausedUntil) {
            c.pausedUntil = until;
            emit HubPaused(hub, until);
        }
    }

    function deny(address[] calldata accounts) external only(denylister) {
        for (uint256 i; i < accounts.length; ++i) {
            denied[accounts[i]] = true;
            emit Denied(accounts[i]);
        }
    }

    // ── Views ───────────────────────────────────────────────────────────

    function isBlocked(address a) public view returns (bool) {
        return denied[a] || sanctions.isSanctioned(a);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _active() internal view returns (Cfg storage c) {
        c = cfg[msg.sender];
        if (!c.configured) revert NotHub();
        if (block.timestamp < c.pausedUntil) revert Paused();
    }

    function _screenInflow(address receiver) internal view {
        if (!cfg[msg.sender].configured) revert NotHub();
        _screen(_ownerOf(_caller()));
        _screen(receiver);
    }

    function _screen(address a) internal view {
        if (isBlocked(a)) revert Blocked(a);
    }

    /// @dev EVC owner of the account's 19-byte prefix, or the account itself if unregistered (A21).
    function _ownerOf(address a) internal view returns (address) {
        address o = evc.getAccountOwner(a);
        return o == address(0) ? a : o;
    }

    function _caller() internal pure returns (address c) {
        if (msg.data.length < 24) revert NotHub();
        assembly {
            c := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    function _setRole(bytes32 role, address a) internal {
        if (role == "owner") owner = a;
        else if (role == "guardian") guardian = a;
        else denylister = a;
        emit RoleSet(role, a);
    }
}
