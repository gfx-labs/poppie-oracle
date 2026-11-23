// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoppieEulerOracle} from "../interfaces/IPoppieEulerOracle.sol";

/// @title OracleAdminGuard (P3)
/// @notice Holds the oracle `admin` slot. Tightening calls and in-band prices land instantly;
///         everything else waits `delay` (`longDelay` for `transferAdmin`).
contract OracleAdminGuard {
    struct Ref {
        uint128 price;
        uint40 start;
    }

    IPoppieEulerOracle public immutable oracle;
    uint256 public immutable bandBps;
    uint256 public immutable delay;
    uint256 public immutable longDelay;

    address public safe;
    address public secondSafe;
    address public guardian;
    address public backupKeeper;

    mapping(bytes32 => uint256) public eta;
    /// @dev Queued second-Safe replacements: only the guardian may cancel them (A6).
    mapping(bytes32 => bool) public guardianOnlyCancel;
    mapping(address => uint128) public prePausePrice;
    mapping(address => Ref) public ref;

    error ZeroAddress();
    error Unauthorized();
    error AlreadyQueued(bytes32 id);
    error NotQueued(bytes32 id);
    error TooEarly(bytes32 id);
    error Expired(bytes32 id);
    error NotApprovable();
    error UseAcceptOracleAdmin();
    error CallFailed();

    event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, address indexed target, bytes data);
    event Approved(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);
    event RoleSet(bytes32 indexed role, address indexed account);
    event PrePauseRecorded(address indexed asset, uint128 price);

    modifier only(address a) {
        if (msg.sender != a) revert Unauthorized();
        _;
    }

    constructor(
        IPoppieEulerOracle oracle_,
        uint256 bandBps_,
        uint256 delay_,
        uint256 longDelay_,
        address safe_,
        address secondSafe_,
        address guardian_,
        address backupKeeper_
    ) {
        if (address(oracle_) == address(0) || safe_ == address(0) || secondSafe_ == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        oracle = oracle_;
        bandBps = bandBps_;
        delay = delay_;
        longDelay = longDelay_;
        _setRole("safe", safe_);
        _setRole("secondSafe", secondSafe_);
        _setRole("guardian", guardian_);
        _setRole("backupKeeper", backupKeeper_);
    }

    // ── Safe ────────────────────────────────────────────────────────────

    function submit(address target, bytes calldata data) external only(safe) {
        bytes32 id = keccak256(abi.encode(target, data));
        if (target == address(oracle)) {
            bytes4 sel = _sel(data);
            if (sel == IPoppieEulerOracle.acceptAdmin.selector) revert UseAcceptOracleAdmin();
            if (sel == IPoppieEulerOracle.pauseAssets.selector) {
                _pause(abi.decode(data[4:], (address[])));
                emit Executed(id, target, data);
                return;
            }
            if (sel == IPoppieEulerOracle.adminSetPrice.selector) {
                (address a, uint128 p) = abi.decode(data[4:], (address, uint128));
                if (_instantPrice(a, p)) {
                    _call(target, data);
                    delete prePausePrice[a];
                    emit Executed(id, target, data);
                    return;
                }
            } else if (_instantOther(sel, data)) {
                _call(target, data);
                emit Executed(id, target, data);
                return;
            }
        }
        _queue(id, target, data);
    }

    function execute(address target, bytes calldata data) external only(safe) {
        bytes32 id = keccak256(abi.encode(target, data));
        uint256 e = eta[id];
        if (e == 0) revert NotQueued(id);
        if (block.timestamp < e) revert TooEarly(id);
        if (block.timestamp > e + delay) revert Expired(id);
        _executeQueued(id, target, data);
    }

    /// @notice The second Safe may land a queued `adminSetPrice` immediately (A8).
    function approveQueued(address target, bytes calldata data) external only(secondSafe) {
        bytes32 id = keccak256(abi.encode(target, data));
        uint256 e = eta[id];
        if (e == 0) revert NotQueued(id);
        if (block.timestamp > e + delay) revert Expired(id);
        if (target != address(oracle) || _sel(data) != IPoppieEulerOracle.adminSetPrice.selector) revert NotApprovable();
        emit Approved(id);
        _executeQueued(id, target, data);
    }

    // ── Guardian / second Safe ──────────────────────────────────────────

    function cancel(bytes32 id) external {
        if (msg.sender != guardian && (msg.sender != secondSafe || guardianOnlyCancel[id])) revert Unauthorized();
        if (eta[id] == 0) revert NotQueued(id);
        delete eta[id];
        delete guardianOnlyCancel[id];
        emit Cancelled(id);
    }

    function pauseAssets(address[] calldata assets) external {
        if (msg.sender != safe && msg.sender != guardian) revert Unauthorized();
        _pause(assets);
    }

    /// @notice Instant guardian replacement, so a rogue guardian cannot block its own removal (A6).
    /// @dev Oracle Safe only. The second Safe must not appoint the guardian: as guardian it could
    ///      cancel its own queued `setSecondSafe` replacement (POP-37).
    function setGuardian(address g) external only(safe) {
        if (g == address(0)) revert ZeroAddress();
        _setRole("guardian", g);
    }

    /// @notice Completes `oracle.transferAdmin(this)`.
    function acceptOracleAdmin() external {
        oracle.acceptAdmin();
    }

    // ── Delayed self-config (reached only via submit + execute) ─────────

    function setSafe(address a) external only(address(this)) {
        if (a == address(0)) revert ZeroAddress();
        _setRole("safe", a);
    }

    function setSecondSafe(address a) external only(address(this)) {
        if (a == address(0)) revert ZeroAddress();
        _setRole("secondSafe", a);
    }

    function setBackupKeeper(address a) external only(address(this)) {
        _setRole("backupKeeper", a);
    }

    // ── Views ───────────────────────────────────────────────────────────

    function idOf(address target, bytes calldata data) external pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _queue(bytes32 id, address target, bytes calldata data) internal {
        uint256 e = eta[id];
        if (e != 0 && block.timestamp <= e + delay) revert AlreadyQueued(id);
        bool isTransfer = target == address(oracle) && _sel(data) == IPoppieEulerOracle.transferAdmin.selector;
        e = block.timestamp + (isTransfer ? longDelay : delay);
        eta[id] = e;
        guardianOnlyCancel[id] = target == address(this) && _sel(data) == this.setSecondSafe.selector;
        emit Queued(id, target, data, e);
    }

    function _executeQueued(bytes32 id, address target, bytes calldata data) internal {
        delete eta[id];
        delete guardianOnlyCancel[id];
        _call(target, data);
        if (target == address(oracle) && _sel(data) == IPoppieEulerOracle.adminSetPrice.selector) {
            (address a, uint128 p) = abi.decode(data[4:], (address, uint128));
            delete prePausePrice[a];
            ref[a] = Ref(p, uint40(block.timestamp));
        }
        emit Executed(id, target, data);
    }

    function _pause(address[] memory assets) internal {
        for (uint256 i; i < assets.length; ++i) {
            uint128 last = oracle.getAssetConfig(assets[i]).lastPrice;
            if (last != 0) {
                prePausePrice[assets[i]] = last;
                emit PrePauseRecorded(assets[i], last);
            }
        }
        oracle.pauseAssets(assets);
    }

    /// @dev Seeding a never-priced asset (A4), or within ±band of the window reference (A3).
    ///      Starts a new window when none is active.
    function _instantPrice(address a, uint128 p) internal returns (bool) {
        IPoppieEulerOracle.AssetConfig memory c = oracle.getAssetConfig(a);
        if (c.configured && !c.paused && c.lastPrice == 0 && prePausePrice[a] == 0) {
            ref[a] = Ref(p, uint40(block.timestamp));
            return true;
        }
        Ref memory r = ref[a];
        bool fresh = r.start == 0 || block.timestamp >= uint256(r.start) + delay;
        uint128 rp = fresh ? (c.lastPrice != 0 ? c.lastPrice : prePausePrice[a]) : r.price;
        if (rp == 0) return false;
        uint256 diff = p > rp ? p - rp : rp - p;
        if (diff * 10_000 > bandBps * rp) return false;
        if (fresh) ref[a] = Ref(rp, uint40(block.timestamp));
        return true;
    }

    /// @dev Instant iff the call only tightens. Zero means "disabled" for breakers and staleness.
    function _instantOther(bytes4 sel, bytes calldata data) internal view returns (bool) {
        if (sel == IPoppieEulerOracle.configureAssets.selector) return true;
        if (sel == IPoppieEulerOracle.setAssetThresholds.selector) {
            (address a, uint16 cb, uint16 cum) = abi.decode(data[4:], (address, uint16, uint16));
            IPoppieEulerOracle.AssetConfig memory c = oracle.getAssetConfig(a);
            return cb != 0 && (c.circuitBreakerThreshold == 0 || cb <= c.circuitBreakerThreshold)
                && cum <= c.cumulativeDeviationCap;
        }
        if (sel == IPoppieEulerOracle.setMaxPriceAge.selector) {
            uint256 x = abi.decode(data[4:], (uint256));
            uint256 old = oracle.maxPriceAge();
            return x != 0 && (old == 0 || x <= old);
        }
        if (sel == IPoppieEulerOracle.setAssetMaxPriceAge.selector) {
            (address a, uint40 x) = abi.decode(data[4:], (address, uint40));
            uint256 g = oracle.maxPriceAge();
            uint256 newEff = x != 0 ? x : g;
            uint256 old = oracle.getAssetConfig(a).maxPriceAge;
            uint256 oldEff = old != 0 ? old : g;
            return newEff != 0 && (oldEff == 0 || newEff <= oldEff);
        }
        if (sel == IPoppieEulerOracle.setKeeper.selector) {
            address k = abi.decode(data[4:], (address));
            return k != address(0) && k == backupKeeper;
        }
        return false;
    }

    /// @dev Function selector of `data`; zero if shorter than 4 bytes.
    function _sel(bytes calldata data) internal pure returns (bytes4) {
        return data.length < 4 ? bytes4(0) : bytes4(data[:4]);
    }

    function _call(address target, bytes calldata data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            if (ret.length == 0) revert CallFailed();
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _setRole(bytes32 role, address a) internal {
        if (role == "safe") safe = a;
        else if (role == "secondSafe") secondSafe = a;
        else if (role == "guardian") guardian = a;
        else backupKeeper = a;
        emit RoleSet(role, a);
    }
}
