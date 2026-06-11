// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {IPoppieEulerOracle} from "./interfaces/IPoppieEulerOracle.sol";

/// @title PoppieEulerOracle
/// @author Oku / gfx labs
/// @notice Price store for Euler. Keeper pushes 18-decimal USD prices per asset,
///         bounded by two guards:
///         1. Per-push circuit breaker — caps single-push deviation vs last price.
///         2. Cumulative deviation cap — caps total drift from a rolling anchor,
///            preventing a compromised keeper from ratcheting prices via many small pushes.
///
///         Reads revert when stale (price age > maxPriceAge).
///
///         Recovery: when a legitimate move exceeds either guard, the keeper can't
///         push, the price goes stale, Euler freezes the asset. Admin calls
///         adminSetPrice to inject the post-move price (bypassing both guards,
///         resetting the anchor) and unfreeze in one tx.
contract PoppieEulerOracle is IPoppieEulerOracle {
    /// @dev basis-point denominator (10000 = 100%).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    mapping(address => AssetConfig) internal _assetConfigs;

    /// @inheritdoc IPoppieEulerOracle
    address public override admin;
    /// @inheritdoc IPoppieEulerOracle
    address public override pendingAdmin;
    /// @inheritdoc IPoppieEulerOracle
    address public override keeper;
    /// @inheritdoc IPoppieEulerOracle
    uint256 public override maxPriceAge;
    /// @inheritdoc IPoppieEulerOracle
    uint256 public override anchorWindow;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    /// @param _admin Initial admin address (non-zero).
    /// @param _keeper Initial keeper address (non-zero).
    /// @param _maxPriceAge Staleness window in seconds (e.g. 3600). 0 disables.
    /// @param _anchorWindow Cumulative-deviation rolling window in seconds (e.g. 86400).
    constructor(address _admin, address _keeper, uint256 _maxPriceAge, uint256 _anchorWindow) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_keeper == address(0)) revert ZeroAddress();
        admin = _admin;
        keeper = _keeper;
        maxPriceAge = _maxPriceAge;
        anchorWindow = _anchorWindow;
        emit OracleDeployed(_admin, _keeper, _maxPriceAge, _anchorWindow);
    }

    // ── Reads ───────────────────────────────────────────────────────────

    /// @inheritdoc IPoppieEulerOracle
    function getPrice(address asset) external view override returns (int256) {
        AssetConfig storage cfg = _assetConfigs[asset];
        int256 price = cfg.lastPrice;

        // revert if no price has been pushed yet
        if (price == 0) revert PriceNotInitialized();

        // revert if the stored price is older than the freshness window
        if (maxPriceAge != 0) {
            if (block.timestamp - cfg.lastPriceTimestamp > maxPriceAge) revert StalePrice();
        }

        return price;
    }

    /// @inheritdoc IPoppieEulerOracle
    function getAssetConfig(address asset) external view override returns (AssetConfig memory) {
        return _assetConfigs[asset];
    }

    // ── Keeper ──────────────────────────────────────────────────────────

    /// @inheritdoc IPoppieEulerOracle
    function keeperPushPrices(
        address[] calldata assets,
        int256[] calldata prices
    ) external override onlyKeeper {
        if (assets.length != prices.length) revert LengthMismatch();

        for (uint256 i = 0; i < assets.length; ++i) {
            // validate price is positive and asset is registered
            if (prices[i] <= 0) revert InvalidPrice();
            if (!_assetConfigs[assets[i]].configured) revert AssetNotConfigured(assets[i]);

            int256 oldPrice = _assetConfigs[assets[i]].lastPrice;

            // guard 1: per-push circuit breaker — skip on first price or when disabled
            if (oldPrice != 0) {
                uint256 threshold = _assetConfigs[assets[i]].circuitBreakerThreshold;
                if (threshold > 0) {
                    uint256 deviationBps = _deviationBps(prices[i], oldPrice);
                    if (deviationBps > threshold) revert CircuitBreakerTriggered(assets[i], deviationBps, threshold);
                }
            }

            // guard 2: cumulative deviation from rolling anchor
            _checkAndUpdateAnchor(assets[i], prices[i]);

            // update last price and timestamp
            _assetConfigs[assets[i]].lastPrice = prices[i];
            _assetConfigs[assets[i]].lastPriceTimestamp = block.timestamp;
        }

        emit PricesRefreshed(assets);
    }

    // ── Admin ───────────────────────────────────────────────────────────

    /// @inheritdoc IPoppieEulerOracle
    function configureAssets(
        address[] calldata assets,
        uint256[] calldata circuitBreakerThresholds,
        uint256[] calldata cumulativeDeviationCaps
    ) external override onlyAdmin {
        if (assets.length != circuitBreakerThresholds.length || assets.length != cumulativeDeviationCaps.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < assets.length; ++i) {
            if (_assetConfigs[assets[i]].configured) revert AssetAlreadyConfigured(assets[i]);

            // initialize asset with thresholds and zeroed price state
            _assetConfigs[assets[i]] = AssetConfig({
                configured: true,
                circuitBreakerThreshold: circuitBreakerThresholds[i],
                cumulativeDeviationCap: cumulativeDeviationCaps[i],
                lastPrice: 0,
                lastPriceTimestamp: 0,
                anchorPrice: 0,
                anchorTimestamp: 0
            });
            emit AssetConfigured(assets[i], circuitBreakerThresholds[i], cumulativeDeviationCaps[i]);
        }
    }

    /// @inheritdoc IPoppieEulerOracle
    function setAssetThresholds(address asset, uint256 circuitBreakerThreshold, uint256 cumulativeDeviationCap) external override onlyAdmin {
        if (!_assetConfigs[asset].configured) revert AssetNotConfigured(asset);
        _assetConfigs[asset].circuitBreakerThreshold = circuitBreakerThreshold;
        _assetConfigs[asset].cumulativeDeviationCap = cumulativeDeviationCap;
        emit AssetThresholdsUpdated(asset, circuitBreakerThreshold, cumulativeDeviationCap);
    }

    /// @inheritdoc IPoppieEulerOracle
    function adminSetPrice(address asset, int256 price) external override onlyAdmin {
        if (price <= 0) revert InvalidPrice();
        if (!_assetConfigs[asset].configured) revert AssetNotConfigured(asset);

        // update last price and timestamp
        _assetConfigs[asset].lastPrice = price;
        _assetConfigs[asset].lastPriceTimestamp = block.timestamp;

        // reset anchor so keeper validates against this new price
        _assetConfigs[asset].anchorPrice = price;
        _assetConfigs[asset].anchorTimestamp = block.timestamp;

        emit AdminPriceForced(asset, price);
    }

    /// @inheritdoc IPoppieEulerOracle
    function setMaxPriceAge(uint256 newMaxPriceAge) external override onlyAdmin {
        emit MaxPriceAgeUpdated(maxPriceAge, newMaxPriceAge);
        maxPriceAge = newMaxPriceAge;
    }

    /// @inheritdoc IPoppieEulerOracle
    function setAnchorWindow(uint256 newAnchorWindow) external override onlyAdmin {
        emit AnchorWindowUpdated(anchorWindow, newAnchorWindow);
        anchorWindow = newAnchorWindow;
    }

    /// @inheritdoc IPoppieEulerOracle
    function setKeeper(address newKeeper) external override onlyAdmin {
        if (newKeeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @inheritdoc IPoppieEulerOracle
    function transferAdmin(address newAdmin) external override onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @inheritdoc IPoppieEulerOracle
    function acceptAdmin() external override {
        if (msg.sender != pendingAdmin) revert NoPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// @dev check cumulative deviation from anchor, reset anchor when window
    ///      expires or on first price.
    function _checkAndUpdateAnchor(address asset, int256 newPrice) internal {
        AssetConfig storage cfg = _assetConfigs[asset];
        uint256 cap = cfg.cumulativeDeviationCap;

        // cumulative guard disabled
        if (cap == 0) return;

        // first price — initialize anchor
        if (cfg.anchorPrice == 0) {
            cfg.anchorPrice = newPrice;
            cfg.anchorTimestamp = block.timestamp;
            return;
        }

        // anchor window expired — reset anchor to current stored price
        if (anchorWindow > 0 && block.timestamp - cfg.anchorTimestamp > anchorWindow) {
            cfg.anchorPrice = cfg.lastPrice;
            cfg.anchorTimestamp = block.timestamp;
        }

        // check total deviation from anchor
        uint256 deviationBps = _deviationBps(newPrice, cfg.anchorPrice);
        if (deviationBps > cap) revert CumulativeDeviationExceeded(asset, deviationBps, cap);
    }

    /// @dev compute |a - b| * 10000 / |b| in basis points.
    function _deviationBps(int256 a, int256 b) internal pure returns (uint256) {
        // absolute difference
        uint256 absDiff = a >= b
            ? uint256(a - b)
            : uint256(b - a);

        // absolute value of denominator
        uint256 absB = b >= 0
            ? uint256(b)
            : uint256(-b);

        // deviation in basis points
        return absDiff * BPS_DENOMINATOR / absB;
    }
}
