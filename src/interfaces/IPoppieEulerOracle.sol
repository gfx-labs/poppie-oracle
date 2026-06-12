// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @title IPoppieEulerOracle
/// @notice Stores 18-decimal USD prices pushed by a keeper, read by PoppieEulerAdapter.
interface IPoppieEulerOracle {
    /// @dev Packed into 2 storage slots (down from 8).
    ///      Slot 1: configured(1) + paused(1) + cbThreshold(2) + cumCap(2)
    ///              + lastTimestamp(5) + anchorTimestamp(5) + lastPrice(16) = 32
    ///      Slot 2: anchorPrice(16) + [16 free]
    ///
    ///      Prices are uint128 (always positive — the contract rejects
    ///      non-positive writes). getPrice returns int256 for Euler
    ///      compatibility by casting on read.
    struct AssetConfig {
        bool configured;                    // 1 byte
        bool paused;                        // 1 byte
        uint16 circuitBreakerThreshold;     // bps; max 10000; 0 disables
        uint16 cumulativeDeviationCap;      // bps; max 10000; 0 disables
        uint40 lastPriceTimestamp;          // unix seconds
        uint40 anchorTimestamp;             // unix seconds
        uint128 lastPrice;                  // 18 decimals; 0 = uninitialized/paused
        // --- slot boundary ---
        uint128 anchorPrice;                // 18 decimals; cumulative check reference
    }

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error LengthMismatch();
    error InvalidPrice();
    error PriceNotInitialized();
    error StalePrice();
    error AssetNotConfigured(address asset);
    error AssetAlreadyConfigured(address asset);
    error CircuitBreakerTriggered(address asset, uint256 deviationBps, uint256 threshold);
    error CumulativeDeviationExceeded(address asset, uint256 deviationBps, uint256 cap);
    error OnlyAdmin();
    error OnlyKeeper();
    error OnlyKeeperOrAdmin();
    error NoPendingAdmin();
    error AssetPaused(address asset);

    // ── Events ──────────────────────────────────────────────────────────

    event AssetConfigured(address indexed asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap);
    event AssetThresholdsUpdated(address indexed asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event PricesRefreshed(address[] assets);
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge, uint256 anchorWindow);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event AnchorWindowUpdated(uint256 oldValue, uint256 newValue);
    event AdminPriceForced(address indexed asset, uint128 price);
    event AssetPausedEvent(address indexed asset);
    event AssetUnpaused(address indexed asset);

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice Returns the stored price (18 decimals). Reverts if uninitialized, paused, or stale.
    function getPrice(address asset) external view returns (int256);

    /// @notice Returns the full config for an asset.
    function getAssetConfig(address asset) external view returns (AssetConfig memory);

    /// @notice Seconds before a stored price is considered stale. 0 disables.
    function maxPriceAge() external view returns (uint256);

    /// @notice Rolling window (seconds) for the cumulative deviation anchor.
    function anchorWindow() external view returns (uint256);

    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function keeper() external view returns (address);

    // ── Keeper ──────────────────────────────────────────────────────────

    /// @notice Push batch of 18-decimal prices. Subject to both guards.
    ///         Paused assets auto-unpause if admin has set a reference and
    ///         the price passes both guards.
    function keeperPushPrices(address[] calldata assets, uint128[] calldata prices) external;

    /// @notice Pause assets. Zeros all price state. Keeper or admin.
    function pauseAssets(address[] calldata assets) external;

    // ── Admin ───────────────────────────────────────────────────────────

    function configureAssets(
        address[] calldata assets,
        uint16[] calldata circuitBreakerThresholds,
        uint16[] calldata cumulativeDeviationCaps
    ) external;

    function setAssetThresholds(address asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap) external;

    /// @notice Force-set price, bypassing guards and resetting anchor.
    function adminSetPrice(address asset, uint128 price) external;

    function setMaxPriceAge(uint256 newMaxPriceAge) external;
    function setAnchorWindow(uint256 newAnchorWindow) external;
    function setKeeper(address newKeeper) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
}
