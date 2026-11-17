// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoppieEulerOracle} from "../interfaces/IPoppieEulerOracle.sol";

/// @title KeeperForwarder (P4)
/// @notice Holds the oracle `keeper` slot. Several keeper keys push independently; keeper-driven
///         pauses share a global budget of `n` assets per fixed window (A12).
contract KeeperForwarder {
    IPoppieEulerOracle public immutable oracle;

    address public admin;
    address public guardian;
    mapping(address => bool) public isKeeper;

    uint32 public n;
    uint32 public window;
    uint40 public windowStart;
    uint32 public used;

    error NotKeeper();
    error BudgetExceeded();
    error Unauthorized();
    error ZeroAddress();

    event KeeperAdded(address indexed keeper);
    event KeeperRemoved(address indexed keeper);
    event BudgetUsed(uint32 used, uint32 n);
    event BudgetSet(uint32 n, uint32 window);
    event RoleSet(bytes32 indexed role, address indexed account);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(IPoppieEulerOracle oracle_, address admin_, address guardian_, uint32 n_, uint32 window_) {
        if (address(oracle_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        admin = admin_;
        guardian = guardian_;
        (n, window) = (n_, window_);
        emit RoleSet("admin", admin_);
        emit RoleSet("guardian", guardian_);
        emit BudgetSet(n_, window_);
    }

    // ── Keepers ─────────────────────────────────────────────────────────

    function push(address[] calldata assets, uint128[] calldata prices) external onlyKeeper {
        oracle.keeperPushPrices(assets, prices);
    }

    function pauseAssets(address[] calldata assets) external onlyKeeper {
        if (block.timestamp >= uint256(windowStart) + window) {
            windowStart = uint40(block.timestamp);
            used = 0;
        }
        uint256 u = uint256(used) + assets.length;
        if (u > n) revert BudgetExceeded();
        used = uint32(u);
        emit BudgetUsed(uint32(u), n);
        oracle.pauseAssets(assets);
    }

    // ── Admin (P3, or the Oracle Safe) ──────────────────────────────────

    function addKeeper(address k) external onlyAdmin {
        if (k == address(0)) revert ZeroAddress();
        isKeeper[k] = true;
        emit KeeperAdded(k);
    }

    function setBudget(uint32 n_, uint32 window_) external onlyAdmin {
        (n, window) = (n_, window_);
        emit BudgetSet(n_, window_);
    }

    function setGuardian(address g) external onlyAdmin {
        guardian = g;
        emit RoleSet("guardian", g);
    }

    function setAdmin(address a) external onlyAdmin {
        if (a == address(0)) revert ZeroAddress();
        admin = a;
        emit RoleSet("admin", a);
    }

    // ── Admin or guardian ───────────────────────────────────────────────

    function removeKeeper(address k) external {
        if (msg.sender != admin && msg.sender != guardian) revert Unauthorized();
        isKeeper[k] = false;
        emit KeeperRemoved(k);
    }
}
