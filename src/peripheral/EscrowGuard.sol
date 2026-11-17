// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVCSubset} from "./interfaces/IEVCSubset.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";

/// @title EscrowGuard (P2)
/// @notice EVK hook target for collateral escrows: issuer pause windows (per group of escrows),
///         guardian deposit pause, sanctions/denylist screening on inflows, optional account freeze.
/// @dev Hook calls carry the authenticated caller in the last 20 bytes of calldata; `msg.sender` is the escrow.
///      Unknown selectors hit an empty `fallback`, so a mis-set bit never blocks an operation.
///      Transfer hooks (OP_TRANSFER, only needed for the freeze) always pass during liquidation seizure.
contract EscrowGuard {
    struct Window {
        uint40 start;
        uint40 end; // exclusive
    }

    IEVCSubset public immutable evc;
    ISanctionsList public immutable sanctions;
    uint256 public immutable maxWindowLen;
    uint256 public immutable maxPerDay;
    uint256 public immutable maxPauseDuration;

    address public owner;
    address public guardian;
    address public scheduler;
    address public denylister;

    mapping(address => address) public groupOf;
    mapping(address => uint40) public pausedUntil;
    mapping(address => mapping(uint256 => Window[])) internal _windows;
    mapping(address => bool) public denied;
    mapping(address => bool) public frozen;

    error NotEscrow();
    error Paused();
    error InWindow();
    error Blocked(address account);
    error Frozen(address account);
    error Unauthorized();
    error ZeroAddress();
    error InvalidWindow();
    error TooManyWindows();
    error InvalidConfig();

    event EscrowSet(address indexed escrow, address indexed group);
    event WindowAdded(address indexed group, uint256 indexed day, uint40 start, uint40 end);
    event WindowsCleared(address indexed group, uint256 indexed day);
    event DepositsPaused(address indexed escrow, uint40 until);
    event DepositsUnpaused(address indexed escrow);
    event Denied(address indexed account);
    event Undenied(address indexed account);
    event FrozenSet(address indexed account, bool frozen);
    event RoleSet(bytes32 indexed role, address indexed account);

    modifier only(address a) {
        if (msg.sender != a) revert Unauthorized();
        _;
    }

    constructor(
        IEVCSubset evc_,
        ISanctionsList sanctions_,
        uint256 maxWindowLen_,
        uint256 maxPerDay_,
        uint256 maxPauseDuration_,
        address owner_,
        address guardian_,
        address scheduler_,
        address denylister_
    ) {
        if (address(evc_) == address(0) || address(sanctions_) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (maxWindowLen_ == 0 || maxWindowLen_ > 1 days || maxPerDay_ == 0 || maxPauseDuration_ > type(uint32).max) {
            revert InvalidConfig();
        }
        evc = evc_;
        sanctions = sanctions_;
        maxWindowLen = maxWindowLen_;
        maxPerDay = maxPerDay_;
        maxPauseDuration = maxPauseDuration_;
        _setRole("owner", owner_);
        _setRole("guardian", guardian_);
        _setRole("scheduler", scheduler_);
        _setRole("denylister", denylister_);
    }

    // ── Hooks ───────────────────────────────────────────────────────────

    function isHookTarget() external pure returns (bytes4) {
        return this.isHookTarget.selector;
    }

    function deposit(uint256, address receiver) external view {
        _inflow(receiver);
    }

    function mint(uint256, address receiver) external view {
        _inflow(receiver);
    }

    function skim(uint256, address receiver) external view {
        _inflow(receiver);
    }

    function withdraw(uint256, address, address shareOwner) external view {
        _outflow();
        _notFrozen(shareOwner);
    }

    function redeem(uint256, address, address shareOwner) external view {
        _outflow();
        _notFrozen(shareOwner);
    }

    function transfer(address, uint256) external view {
        if (evc.isControlCollateralInProgress()) return; // seizure always passes
        _notFrozen(_caller());
    }

    function transferFrom(address from, address, uint256) external view {
        if (evc.isControlCollateralInProgress()) return;
        _notFrozen(from);
    }

    function transferFromMax(address from, address) external view {
        if (evc.isControlCollateralInProgress()) return;
        _notFrozen(from);
    }

    fallback() external {}

    // ── Owner (MS_OPS) ──────────────────────────────────────────────────

    /// @notice Map an escrow to an issuer group (A23); `group == 0` unconfigures it.
    function setEscrow(address escrow, address group) external only(owner) {
        groupOf[escrow] = group;
        emit EscrowSet(escrow, group);
    }

    function clearWindows(address group, uint256 day) external only(owner) {
        delete _windows[group][day];
        emit WindowsCleared(group, day);
    }

    function unpause(address escrow) external only(owner) {
        pausedUntil[escrow] = 0;
        emit DepositsUnpaused(escrow);
    }

    function removeDenied(address a) external only(owner) {
        denied[a] = false;
        emit Undenied(a);
    }

    function unfreeze(address a) external only(owner) {
        frozen[a] = false;
        emit FrozenSet(a, false);
    }

    function setOwner(address a) external only(owner) {
        if (a == address(0)) revert ZeroAddress();
        _setRole("owner", a);
    }

    function setGuardian(address a) external only(owner) {
        _setRole("guardian", a);
    }

    function setScheduler(address a) external only(owner) {
        _setRole("scheduler", a);
    }

    function setDenylister(address a) external only(owner) {
        _setRole("denylister", a);
    }

    // ── Hot keys: add-only / raise-only ─────────────────────────────────

    function pauseDeposits(address escrow, uint256 duration) external only(guardian) {
        if (duration > maxPauseDuration) revert InvalidConfig();
        // forge-lint: disable-next-line(unsafe-typecast) duration <= type(uint32).max (constructor): fits uint40
        uint40 until = uint40(block.timestamp + duration);
        if (until > pausedUntil[escrow]) {
            pausedUntil[escrow] = until;
            emit DepositsPaused(escrow, until);
        }
    }

    /// @notice Add a future window `[start, end)` within one UTC day, at most `maxWindowLen` long.
    function addWindow(address group, uint40 start, uint40 end) external only(scheduler) {
        if (group == address(0) || start < block.timestamp || end <= start || end - start > maxWindowLen) {
            revert InvalidWindow();
        }
        uint256 day = start / 1 days;
        if ((end - 1) / 1 days != day) revert InvalidWindow(); // no midnight crossing
        Window[] storage w = _windows[group][day];
        if (w.length >= maxPerDay) revert TooManyWindows();
        w.push(Window(start, end));
        emit WindowAdded(group, day, start, end);
    }

    function deny(address[] calldata accounts) external only(denylister) {
        for (uint256 i; i < accounts.length; ++i) {
            denied[accounts[i]] = true;
            emit Denied(accounts[i]);
        }
    }

    /// @notice Block withdrawals and transfers of an account (and of its EVC sub-accounts), e.g. under a
    ///         court order. Liquidation seizure still passes.
    function freeze(address[] calldata accounts) external only(denylister) {
        for (uint256 i; i < accounts.length; ++i) {
            frozen[accounts[i]] = true;
            emit FrozenSet(accounts[i], true);
        }
    }

    // ── Views ───────────────────────────────────────────────────────────

    function windowsOf(address group, uint256 day) external view returns (Window[] memory) {
        return _windows[group][day];
    }

    function inWindow(address group) public view returns (bool) {
        Window[] storage w = _windows[group][block.timestamp / 1 days];
        for (uint256 i; i < w.length; ++i) {
            if (block.timestamp >= w[i].start && block.timestamp < w[i].end) return true;
        }
        return false;
    }

    function isBlocked(address a) public view returns (bool) {
        return denied[a] || sanctions.isSanctioned(a);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _inflow(address receiver) internal view {
        address group = groupOf[msg.sender];
        if (group == address(0)) revert NotEscrow();
        if (block.timestamp < pausedUntil[msg.sender]) revert Paused();
        if (inWindow(group)) revert InWindow();
        _screen(_ownerOf(_caller()));
        _screen(receiver);
    }

    /// @dev Unconfigured escrows never block exits.
    function _outflow() internal view {
        address group = groupOf[msg.sender];
        if (group != address(0) && inWindow(group)) revert InWindow();
    }

    function _notFrozen(address a) internal view {
        if (frozen[a]) revert Frozen(a);
        address o = _ownerOf(a);
        if (frozen[o]) revert Frozen(o);
    }

    function _screen(address a) internal view {
        if (isBlocked(a)) revert Blocked(a);
    }

    function _ownerOf(address a) internal view returns (address) {
        address o = evc.getAccountOwner(a);
        return o == address(0) ? a : o;
    }

    function _caller() internal pure returns (address c) {
        if (msg.data.length < 24) revert NotEscrow();
        assembly {
            c := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    function _setRole(bytes32 role, address a) internal {
        if (role == "owner") owner = a;
        else if (role == "guardian") guardian = a;
        else if (role == "scheduler") scheduler = a;
        else denylister = a;
        emit RoleSet(role, a);
    }
}
