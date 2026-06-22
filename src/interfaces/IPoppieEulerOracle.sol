// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPoppieEulerOracle
/// @notice Stores 18-decimal USD prices pushed by a keeper, read by PoppieEulerAdapter.
interface IPoppieEulerOracle {
    /// @dev Packed into 2 storage slots (down from 8).
    ///      Slot 1: configured(1) + paused(1) + cbThreshold(2) + cumCap(2)
    ///              + lastTimestamp(5) + anchorTimestamp(5) + lastPrice(16) = 32
    ///      Slot 2: anchorPrice(16) + maxPriceAge(5) + [11 free]
    ///
    ///      Prices are uint128 (always positive — the contract rejects
    ///      non-positive writes). getPrice returns int256 for Euler
    ///      compatibility by casting on read.
    ///
    ///      `maxPriceAge` is per-asset: when non-zero it overrides the global
    ///      `maxPriceAge` for this asset. When zero, the global default
    ///      applies. A uint40 fits 34,000+ years which is well beyond any
    ///      sensible staleness window.
    struct AssetConfig {
        bool configured;                    // 1 byte
        bool paused;                        // 1 byte
        uint16 circuitBreakerThreshold;     // bps; max 10000; 0 disables
        uint16 cumulativeDeviationCap;      // bps; max 10000; 0 disables
        uint40 lastPriceTimestamp;          // unix seconds
        uint40 anchorTimestamp;             // unix seconds
        uint128 lastPrice;                  // 18 decimals; 0 = unseeded
                                            // (fresh-configured, or freshly-paused;
                                            // admin must call `adminSetPrice`
                                            // before keeper can push)
        // --- slot boundary ---
        uint128 anchorPrice;                // 18 decimals; cumulative check reference
        uint40 maxPriceAge;                 // 0 = inherit global; non-zero = per-asset override
    }

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error LengthMismatch();
    error InvalidConfig();
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
    /// @dev Raised by `acceptAdmin` when no pending admin transfer is in flight
    ///      (i.e. `pendingAdmin == address(0)`). Distinct from `NotPendingAdmin`
    ///      which signals an unauthorized caller during an active transfer.
    error NoPendingAdmin();
    /// @dev Raised by `acceptAdmin` when a pending admin transfer is in flight
    ///      but the caller is not the pending admin. Distinguishing this from
    ///      `NoPendingAdmin` lets off-chain monitoring tell a benign
    ///      configuration state apart from an unauthorized take-over attempt.
    error NotPendingAdmin();
    error AssetIsPaused(address asset);
    error AssetAlreadyPaused(address asset);

    // ── Events ──────────────────────────────────────────────────────────

    event AssetConfigured(address indexed asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap);
    event AssetThresholdsUpdated(address indexed asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    /// @notice Emitted once per asset for every accepted keeper push. Indexers
    ///         should subscribe to this event (not `PricesRefreshed`) to track
    ///         price history, since the topic-indexed `asset` is filterable.
    event PriceUpdated(address indexed asset, uint128 oldPrice, uint128 newPrice, uint40 timestamp);

    /// @notice Emitted once per `keeperPushPrices` call as a tx-level marker.
    ///         Carries the unindexed batch contents. Use `PriceUpdated` for
    ///         per-asset history.
    event PricesRefreshed(address[] assets);
    event OracleDeployed(address indexed admin, address indexed keeper, uint256 maxPriceAge, uint256 anchorWindow);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Emitted whenever the per-asset staleness override changes
    ///         (including being cleared back to the global default at 0).
    event AssetMaxPriceAgeUpdated(address indexed asset, uint40 oldValue, uint40 newValue);
    event AnchorWindowUpdated(uint256 oldValue, uint256 newValue);
    event AdminPriceForced(address indexed asset, uint128 price);
    event AssetPaused(address indexed asset);
    event AssetUnpaused(address indexed asset);
    /// @notice Emitted on the keeper-push path whenever the rolling anchor is
    ///         rotated by the cumulative-drift guard. `newAnchor` is the value
    ///         the next push will be measured against. Off-chain monitoring
    ///         should subscribe to this event to detect anchor resets.
    event AnchorRotated(address indexed asset, uint128 oldAnchor, uint128 newAnchor, uint40 timestamp);

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

    /// @notice Push a batch of 18-decimal prices. Each price is subject to two
    ///         guards: the per-push circuit breaker and the cumulative drift cap.
    /// @dev    Behavioral notes for auditors and integrators:
    ///
    ///         1. Duplicate assets within a single batch ARE permitted. The
    ///            implementation processes the array in order, so the second
    ///            (and subsequent) entries for the same asset are validated
    ///            against the price written by the previous entry. The
    ///            cumulative drift guard (which is mandatory — see
    ///            `configureAssets`) bounds the total movement across the
    ///            batch. Reordering by the keeper does not increase risk
    ///            beyond what the guards already enforce.
    ///
    ///         2. AUTO-UNPAUSE: a paused asset that has been re-seeded via
    ///            `adminSetPrice` will silently un-pause on the next keeper
    ///            push that passes both guards. This is by design — pause is
    ///            a transient state and the admin's reseed is the explicit
    ///            "ready to resume" signal. There is no separate
    ///            `adminResume`; pausing and resuming are split between
    ///            `pauseAssets`/`adminSetPrice` respectively.
    ///
    ///         3. Reverts (non-exhaustive): empty arrays, length mismatch,
    ///            zero price, unconfigured asset, paused-and-unseeded asset
    ///            (`AssetIsPaused`), unconfigured-and-unseeded asset
    ///            (`PriceNotInitialized`), per-push breaker, cumulative cap.
    function keeperPushPrices(address[] calldata assets, uint128[] calldata prices) external;

    /// @notice Pause one or more assets. Zeros all price state for each, so
    ///         the next keeper push will revert until admin re-seeds via
    ///         `adminSetPrice`. Callable by keeper or admin.
    /// @dev    There is intentionally no `adminUnpause` counterpart: recovery
    ///         is a two-step admin-then-keeper handshake. Admin re-seeds via
    ///         `adminSetPrice`, then the keeper's next valid push auto-unpauses
    ///         the asset. This guarantees that an unpaused asset is always
    ///         backed by a price that has passed the keeper-side guards
    ///         (circuit breaker + cumulative cap) rather than just an admin
    ///         force-write. See audit L-02 for the operational trade-off
    ///         (recovery requires keeper cooperation, by design).
    function pauseAssets(address[] calldata assets) external;

    // ── Admin ───────────────────────────────────────────────────────────

    function configureAssets(
        address[] calldata assets,
        uint16[] calldata circuitBreakerThresholds,
        uint16[] calldata cumulativeDeviationCaps
    ) external;

    function setAssetThresholds(address asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap) external;

    /// @notice Force-set the stored price for an asset.
    /// @dev    This is an UNCHECKED admin primitive. It deliberately bypasses
    ///         both the per-push circuit breaker and the cumulative drift cap,
    ///         and resets the rolling anchor (both `anchorPrice` and
    ///         `anchorTimestamp`) to the new value. It also has no upper
    ///         sanity bound on `price` — admin may write any non-zero
    ///         uint128. This is the intended recovery primitive used to (a)
    ///         seed a freshly-configured asset, (b) recover a paused asset,
    ///         or (c) force a re-base after an incident that would
    ///         legitimately trip the guards. Misuse is contained by the same
    ///         trust model as every other `onlyAdmin` setter.
    function adminSetPrice(address asset, uint128 price) external;

    /// @notice Update the GLOBAL staleness window applied by `getPrice` for
    ///         any asset that does not have a per-asset override.
    /// @dev    Passing `0` is an INTENTIONAL opt-out: when both the per-asset
    ///         override and the global value are `0`, `getPrice` skips the
    ///         staleness check entirely and will return arbitrarily old
    ///         prices. This is reserved for incident response (e.g. keeper
    ///         offline) and should not be the steady-state configuration.
    ///         Admins are expected to restore a non-zero value once normal
    ///         operation resumes.
    function setMaxPriceAge(uint256 newMaxPriceAge) external;

    /// @notice Override the staleness window for a specific asset.
    /// @dev    Tokenised equities trade on different schedules and have
    ///         different liquidity profiles. The per-asset override lets the
    ///         admin tighten the freshness guarantee on liquid names while
    ///         keeping a looser window on assets with legitimate update gaps.
    ///         Passing `0` clears the override and reinstates the global
    ///         `maxPriceAge`. The asset must already be configured.
    function setAssetMaxPriceAge(address asset, uint40 newMaxPriceAge) external;

    /// @notice Update the rolling-anchor window used by the cumulative drift guard.
    /// @dev    Passing `0` is an INTENTIONAL opt-out: when `anchorWindow == 0`
    ///         the anchor never rotates and the cumulative cap is measured
    ///         against the originally-seeded price until admin re-seeds via
    ///         `adminSetPrice`. Use sparingly; this freezes the cumulative
    ///         reference for the lifetime of the seed.
    function setAnchorWindow(uint256 newAnchorWindow) external;
    function setKeeper(address newKeeper) external;
    function transferAdmin(address newAdmin) external;

    /// @notice Accept a pending admin transfer. Must be called by the address
    ///         set via `transferAdmin`.
    /// @dev    Reverts with `NoPendingAdmin` when no transfer is in flight
    ///         (`pendingAdmin == address(0)`), and `NotPendingAdmin` when a
    ///         transfer is in flight but the caller is not the pending admin.
    function acceptAdmin() external;
}
