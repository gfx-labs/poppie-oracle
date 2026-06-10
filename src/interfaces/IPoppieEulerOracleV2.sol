// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPoppieEulerOracleV2
/// @notice Interface for the PoppieEuler oracle: the singleton that stores
///         validated 18-decimal prices for all Ondo assets and is read by
///         PoppieEulerAdapter via `getPrice`.
interface IPoppieEulerOracleV2 {
    // --- Structs ---

    struct AssetConfig {
        bool configured; // true once configured; gates writes/recovery
        uint256 circuitBreakerThreshold; // basis points (5000 = 50%)
        int256 lastPrice; // last validated price (18 decimals)
        uint256 lastPriceTimestamp;
    }

    // --- Events ---

    event AssetConfigured(address indexed asset);
    event CircuitBreakerThresholdSet(address indexed asset, uint256 threshold);
    event KeeperUpdated(address oldKeeper, address newKeeper);
    event AdminUpdated(address oldAdmin, address newAdmin);
    event PricesRefreshed(address[] assets);

    /// @notice Emitted once at deployment so indexers can discover a new oracle and
    ///         its initial admin/keeper and freshness window from logs alone.
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge);

    /// @notice Emitted when the admin changes the read-path freshness window.
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when the admin force-pushes a price (circuit-breaker bypass
    ///         recovery). Distinct from PricesRefreshed so dashboards and alerts can
    ///         clearly flag a manual intervention.
    event AdminPriceForced(address indexed asset, int256 price);

    // --- View Functions ---

    function getPrice(address asset) external view returns (int256);
    function getAssetConfig(address asset) external view returns (AssetConfig memory);
    function maxPriceAge() external view returns (uint256);
    function admin() external view returns (address);
    function keeper() external view returns (address);

    // --- Keeper Functions ---

    function keeperPushPrices(address[] calldata assets, int256[] calldata prices) external;

    // --- Admin Functions ---

    function configureAssets(
        address[] calldata assets,
        uint256[] calldata circuitBreakerThresholds
    ) external;
    function setCircuitBreakerThreshold(address asset, uint256 threshold) external;

    /// @notice Admin force-push recovery lever (single + batch).
    function adminSetPrice(address asset, int256 price) external;
    function adminSetPrices(address[] calldata assets, int256[] calldata prices) external;

    /// @notice Admin sets the read-path freshness window (seconds).
    function setMaxPriceAge(uint256 newMaxPriceAge) external;

    function setKeeper(address newKeeper) external;
    function setAdmin(address newAdmin) external;
}
