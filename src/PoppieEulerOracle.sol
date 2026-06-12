// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {IPoppieEulerOracle} from "./interfaces/IPoppieEulerOracle.sol";

/// @title PoppieEulerOracle
/// @author Oku / gfx labs
/// @notice Price store for Euler. Keeper pushes 18-decimal USD prices per asset,
///         bounded by a per-push circuit breaker and a cumulative deviation cap.
///         Reads revert when stale or paused.
///
///         AssetConfig is packed into 2 storage slots. Prices are uint128
///         (always positive). The hot path writes at most 2 SSTOREs/asset.
contract PoppieEulerOracle is IPoppieEulerOracle {
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
        if (cfg.paused) revert AssetPaused(asset);
        uint128 price = cfg.lastPrice;
        if (price == 0) revert PriceNotInitialized();
        uint256 _maxAge = maxPriceAge;
        if (_maxAge != 0) {
            if (block.timestamp - uint256(cfg.lastPriceTimestamp) > _maxAge) revert StalePrice();
        }
        return int256(uint256(price));
    }

    /// @inheritdoc IPoppieEulerOracle
    function getAssetConfig(address asset) external view override returns (AssetConfig memory) {
        return _assetConfigs[asset];
    }

    // ── Keeper ──────────────────────────────────────────────────────────

    /// @inheritdoc IPoppieEulerOracle
    function keeperPushPrices(
        address[] calldata assets,
        uint128[] calldata prices
    ) external override onlyKeeper {
        if (assets.length != prices.length) revert LengthMismatch();
        uint40 ts = uint40(block.timestamp);

        for (uint256 i; i < assets.length;) {
            if (prices[i] == 0) revert InvalidPrice();
            AssetConfig storage cfg = _assetConfigs[assets[i]];
            if (!cfg.configured) revert AssetNotConfigured(assets[i]);

            uint128 oldPrice = cfg.lastPrice;

            // paused assets need admin reference (oldPrice != 0) before keeper can unpause
            if (cfg.paused) {
                if (oldPrice == 0) revert AssetPaused(assets[i]);
            }

            // guard 1: per-push circuit breaker
            if (oldPrice != 0) {
                uint256 threshold = uint256(cfg.circuitBreakerThreshold);
                if (threshold != 0) {
                    uint256 dev = _deviationBps(prices[i], oldPrice);
                    if (dev > threshold) revert CircuitBreakerTriggered(assets[i], dev, threshold);
                }
            }

            // guard 2: cumulative deviation from rolling anchor
            _checkAndUpdateAnchor(cfg, prices[i], assets[i], ts);

            // auto-unpause after guards pass
            if (cfg.paused) {
                cfg.paused = false;
                emit AssetUnpaused(assets[i]);
            }

            // update price + timestamp (same slot)
            cfg.lastPrice = prices[i];
            cfg.lastPriceTimestamp = ts;

            unchecked { ++i; }
        }

        emit PricesRefreshed(assets);
    }

    /// @inheritdoc IPoppieEulerOracle
    function pauseAssets(address[] calldata assets) external override {
        if (msg.sender != keeper && msg.sender != admin) revert OnlyKeeperOrAdmin();
        for (uint256 i; i < assets.length;) {
            AssetConfig storage cfg = _assetConfigs[assets[i]];
            if (!cfg.configured) revert AssetNotConfigured(assets[i]);
            if (cfg.paused) revert AssetPaused(assets[i]);
            cfg.paused = true;
            cfg.lastPrice = 0;
            cfg.lastPriceTimestamp = 0;
            cfg.anchorPrice = 0;
            cfg.anchorTimestamp = 0;
            emit AssetPausedEvent(assets[i]);
            unchecked { ++i; }
        }
    }

    // ── Admin ───────────────────────────────────────────────────────────

    /// @inheritdoc IPoppieEulerOracle
    function configureAssets(
        address[] calldata assets,
        uint16[] calldata circuitBreakerThresholds,
        uint16[] calldata cumulativeDeviationCaps
    ) external override onlyAdmin {
        if (assets.length != circuitBreakerThresholds.length || assets.length != cumulativeDeviationCaps.length) {
            revert LengthMismatch();
        }
        for (uint256 i; i < assets.length;) {
            if (_assetConfigs[assets[i]].configured) revert AssetAlreadyConfigured(assets[i]);
            _assetConfigs[assets[i]] = AssetConfig({
                configured: true,
                paused: false,
                circuitBreakerThreshold: circuitBreakerThresholds[i],
                cumulativeDeviationCap: cumulativeDeviationCaps[i],
                lastPriceTimestamp: 0,
                anchorTimestamp: 0,
                lastPrice: 0,
                anchorPrice: 0
            });
            emit AssetConfigured(assets[i], circuitBreakerThresholds[i], cumulativeDeviationCaps[i]);
            unchecked { ++i; }
        }
    }

    /// @inheritdoc IPoppieEulerOracle
    function setAssetThresholds(address asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap) external override onlyAdmin {
        if (!_assetConfigs[asset].configured) revert AssetNotConfigured(asset);
        _assetConfigs[asset].circuitBreakerThreshold = circuitBreakerThreshold;
        _assetConfigs[asset].cumulativeDeviationCap = cumulativeDeviationCap;
        emit AssetThresholdsUpdated(asset, circuitBreakerThreshold, cumulativeDeviationCap);
    }

    /// @inheritdoc IPoppieEulerOracle
    function adminSetPrice(address asset, uint128 price) external override onlyAdmin {
        if (price == 0) revert InvalidPrice();
        AssetConfig storage cfg = _assetConfigs[asset];
        if (!cfg.configured) revert AssetNotConfigured(asset);
        uint40 ts = uint40(block.timestamp);
        cfg.lastPrice = price;
        cfg.lastPriceTimestamp = ts;
        cfg.anchorPrice = price;
        cfg.anchorTimestamp = ts;
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

    function _checkAndUpdateAnchor(AssetConfig storage cfg, uint128 newPrice, address asset, uint40 ts) internal {
        uint256 cap = uint256(cfg.cumulativeDeviationCap);
        if (cap == 0) return;

        uint128 anchor = cfg.anchorPrice;
        if (anchor == 0) {
            cfg.anchorPrice = newPrice;
            cfg.anchorTimestamp = ts;
            return;
        }

        uint256 _window = anchorWindow;
        if (_window != 0 && block.timestamp - uint256(cfg.anchorTimestamp) > _window) {
            anchor = cfg.lastPrice;
            cfg.anchorPrice = anchor;
            cfg.anchorTimestamp = ts;
        }

        uint256 dev = _deviationBps(newPrice, anchor);
        if (dev > cap) revert CumulativeDeviationExceeded(asset, dev, cap);
    }

    function _deviationBps(uint128 a, uint128 b) internal pure returns (uint256) {
        unchecked {
            uint256 diff = a >= b
                ? uint256(a - b)
                : uint256(b - a);
            return diff * BPS_DENOMINATOR / uint256(b);
        }
    }
}
