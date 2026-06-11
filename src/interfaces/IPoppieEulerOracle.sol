// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @title IPoppieEulerOracle
/// @notice Stores 18-decimal USD prices pushed by a keeper, read by PoppieEulerAdapter.
interface IPoppieEulerOracle {
    struct AssetConfig {
        bool configured;
        uint256 circuitBreakerThreshold;  // per-push max move in bps; 0 disables
        uint256 cumulativeDeviationCap;   // max total move from anchor in bps; 0 disables
        int256 lastPrice;                 // 18 decimals
        uint256 lastPriceTimestamp;       // block.timestamp of last write
        int256 anchorPrice;               // reference price for cumulative check
        uint256 anchorTimestamp;          // when the anchor was set
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
    error NoPendingAdmin();

    // ── Events ──────────────────────────────────────────────────────────

    event AssetConfigured(address indexed asset, uint256 circuitBreakerThreshold, uint256 cumulativeDeviationCap);
    event AssetThresholdsUpdated(address indexed asset, uint256 circuitBreakerThreshold, uint256 cumulativeDeviationCap);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event PricesRefreshed(address[] assets);
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge, uint256 anchorWindow);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event AnchorWindowUpdated(uint256 oldValue, uint256 newValue);
    event AdminPriceForced(address indexed asset, int256 price);

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice Returns the stored price (18 decimals). Reverts if uninitialized or stale.
    /// @param asset The token address.
    /// @return The price as int256 (always positive).
    function getPrice(address asset) external view returns (int256);

    /// @notice Returns the full config for an asset.
    /// @param asset The token address.
    function getAssetConfig(address asset) external view returns (AssetConfig memory);

    /// @notice Seconds before a stored price is considered stale. 0 disables.
    function maxPriceAge() external view returns (uint256);

    /// @notice Rolling window (seconds) for the cumulative deviation anchor.
    function anchorWindow() external view returns (uint256);

    /// @notice The admin address.
    function admin() external view returns (address);

    /// @notice The pending admin address (zero if no transfer in progress).
    function pendingAdmin() external view returns (address);

    /// @notice The authorized keeper address.
    function keeper() external view returns (address);

    // ── Keeper ──────────────────────────────────────────────────────────

    /// @notice Push batch of 18-decimal prices. Keeper-only, subject to both guards.
    /// @param assets Token addresses.
    /// @param prices Corresponding 18-decimal USD prices (must be > 0).
    function keeperPushPrices(address[] calldata assets, int256[] calldata prices) external;

    // ── Admin ───────────────────────────────────────────────────────────

    /// @notice Register new assets with their guard thresholds. Reverts if already configured.
    /// @param assets Token addresses.
    /// @param circuitBreakerThresholds Per-push max deviation in bps per asset.
    /// @param cumulativeDeviationCaps Max total deviation from anchor in bps per asset.
    function configureAssets(
        address[] calldata assets,
        uint256[] calldata circuitBreakerThresholds,
        uint256[] calldata cumulativeDeviationCaps
    ) external;

    /// @notice Update both guard thresholds for a configured asset.
    /// @param asset The token address (must be configured).
    /// @param circuitBreakerThreshold New per-push threshold in bps.
    /// @param cumulativeDeviationCap New cumulative cap in bps.
    function setAssetThresholds(address asset, uint256 circuitBreakerThreshold, uint256 cumulativeDeviationCap) external;

    /// @notice Force-set price, bypassing both guards and resetting the anchor.
    /// @param asset The token address.
    /// @param price New 18-decimal price (must be > 0).
    function adminSetPrice(address asset, int256 price) external;

    /// @notice Set the staleness window. 0 disables the freshness check.
    /// @param newMaxPriceAge New window in seconds.
    function setMaxPriceAge(uint256 newMaxPriceAge) external;

    /// @notice Set the cumulative deviation anchor window.
    /// @param newAnchorWindow New window in seconds.
    function setAnchorWindow(uint256 newAnchorWindow) external;

    /// @notice Transfer keeper role.
    /// @param newKeeper New keeper address (must be non-zero).
    function setKeeper(address newKeeper) external;

    /// @notice Start a two-step admin transfer. The new admin must call acceptAdmin.
    /// @param newAdmin Proposed new admin address (must be non-zero).
    function transferAdmin(address newAdmin) external;

    /// @notice Accept a pending admin transfer. Must be called by the pending admin.
    function acceptAdmin() external;
}
