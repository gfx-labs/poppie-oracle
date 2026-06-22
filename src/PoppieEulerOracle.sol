// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
        if (cfg.paused) revert AssetIsPaused(asset);
        uint128 price = cfg.lastPrice;
        if (price == 0) revert PriceNotInitialized();
        // per-asset override takes precedence over the global default. either
        // being zero means "no staleness guard for this asset"; both must be
        // zero to disable the check entirely.
        uint256 _maxAge = uint256(cfg.maxPriceAge);
        if (_maxAge == 0) _maxAge = maxPriceAge;
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
        if (assets.length == 0) revert LengthMismatch();
        if (assets.length != prices.length) revert LengthMismatch();
        uint40 ts = uint40(block.timestamp);

        for (uint256 i = 0; i < assets.length; ++i) {
            if (prices[i] == 0) revert InvalidPrice();
            AssetConfig storage cfg = _assetConfigs[assets[i]];
            if (!cfg.configured) revert AssetNotConfigured(assets[i]);

            uint128 oldPrice = cfg.lastPrice;

            // require a seeded price before any keeper push. for a fresh asset admin must
            // call adminSetPrice first; for a paused asset admin must set the recovery
            // reference. this also makes both guards below unconditionally active.
            if (oldPrice == 0) {
                if (cfg.paused) revert AssetIsPaused(assets[i]);
                revert PriceNotInitialized();
            }

            // guard 1: per-push circuit breaker
            uint256 threshold = uint256(cfg.circuitBreakerThreshold);
            if (threshold != 0) {
                uint256 dev = _deviationBps(prices[i], oldPrice);
                if (dev > threshold) revert CircuitBreakerTriggered(assets[i], dev, threshold);
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

            emit PriceUpdated(assets[i], oldPrice, prices[i], ts);
        }

        emit PricesRefreshed(assets);
    }

    /// @inheritdoc IPoppieEulerOracle
    function pauseAssets(address[] calldata assets) external override {
        if (msg.sender != keeper && msg.sender != admin) revert OnlyKeeperOrAdmin();
        if (assets.length == 0) revert LengthMismatch();
        for (uint256 i = 0; i < assets.length; ++i) {
            AssetConfig storage cfg = _assetConfigs[assets[i]];
            if (!cfg.configured) revert AssetNotConfigured(assets[i]);
            if (cfg.paused) revert AssetAlreadyPaused(assets[i]);
            cfg.paused = true;
            cfg.lastPrice = 0;
            cfg.lastPriceTimestamp = 0;
            cfg.anchorPrice = 0;
            cfg.anchorTimestamp = 0;
            emit AssetPaused(assets[i]);
        }
    }

    // ── Admin ───────────────────────────────────────────────────────────

    /// @inheritdoc IPoppieEulerOracle
    function configureAssets(
        address[] calldata assets,
        uint16[] calldata circuitBreakerThresholds,
        uint16[] calldata cumulativeDeviationCaps
    ) external override onlyAdmin {
        if (assets.length == 0) revert LengthMismatch();
        if (assets.length != circuitBreakerThresholds.length || assets.length != cumulativeDeviationCaps.length) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < assets.length; ++i) {
            if (_assetConfigs[assets[i]].configured) revert AssetAlreadyConfigured(assets[i]);
            // require non-zero cumulative cap so the multi-step drift guard is always active.
            // this is the only guard that defends a duplicate-asset batch in keeperPushPrices.
            if (cumulativeDeviationCaps[i] == 0) revert InvalidConfig();
            // bps values must be <= 10000 (100%). anything larger silently disables
            // the guard from the consumer's perspective and is almost certainly a misconfig.
            if (circuitBreakerThresholds[i] > BPS_DENOMINATOR) revert InvalidConfig();
            if (cumulativeDeviationCaps[i] > BPS_DENOMINATOR) revert InvalidConfig();
            _assetConfigs[assets[i]] = AssetConfig({
                configured: true,
                paused: false,
                circuitBreakerThreshold: circuitBreakerThresholds[i],
                cumulativeDeviationCap: cumulativeDeviationCaps[i],
                lastPriceTimestamp: 0,
                anchorTimestamp: 0,
                lastPrice: 0,
                anchorPrice: 0,
                maxPriceAge: 0  // inherit global by default; override via setAssetMaxPriceAge
            });
            emit AssetConfigured(assets[i], circuitBreakerThresholds[i], cumulativeDeviationCaps[i]);
        }
    }

    /// @inheritdoc IPoppieEulerOracle
    function setAssetThresholds(address asset, uint16 circuitBreakerThreshold, uint16 cumulativeDeviationCap) external override onlyAdmin {
        if (!_assetConfigs[asset].configured) revert AssetNotConfigured(asset);
        // mirror the configureAssets invariants: cumulative cap must remain
        // non-zero, and both bps values must be <= 10000.
        if (cumulativeDeviationCap == 0) revert InvalidConfig();
        if (circuitBreakerThreshold > BPS_DENOMINATOR) revert InvalidConfig();
        if (cumulativeDeviationCap > BPS_DENOMINATOR) revert InvalidConfig();
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
    function setAssetMaxPriceAge(address asset, uint40 newMaxPriceAge) external override onlyAdmin {
        AssetConfig storage cfg = _assetConfigs[asset];
        if (!cfg.configured) revert AssetNotConfigured(asset);
        emit AssetMaxPriceAgeUpdated(asset, cfg.maxPriceAge, newMaxPriceAge);
        cfg.maxPriceAge = newMaxPriceAge;
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
        // distinguish "no transfer in flight" from "unauthorized caller during
        // a transfer" so off-chain monitoring can tell a benign configuration
        // state apart from an attempted take-over.
        address _pending = pendingAdmin;
        if (_pending == address(0)) revert NoPendingAdmin();
        if (msg.sender != _pending) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// @dev Cumulative-drift check. Compares `newPrice` against the rolling anchor.
    ///      When the window expires we rotate the anchor to the price being
    ///      accepted right now (`newPrice`), so every new window starts from
    ///      the just-accepted level and the cumulative cap measures drift
    ///      from that point forward. This eliminates the boundary asymmetry
    ///      where a rotated anchor sits at the previous push (potentially
    ///      far from the current price) and artificially inflates the
    ///      apparent deviation of the very next push.
    ///
    ///      Note that the rotation push itself is therefore implicitly within
    ///      the cap (deviation of `newPrice` from itself is 0); the per-push
    ///      circuit breaker remains the bound on a single rotation-push step.
    ///
    ///      Setting `anchorWindow = 0` disables rotation entirely, freezing
    ///      the anchor at the first seeded value until admin re-seeds via
    ///      `adminSetPrice`.
    function _checkAndUpdateAnchor(AssetConfig storage cfg, uint128 newPrice, address asset, uint40 ts) internal {
        uint256 cap = uint256(cfg.cumulativeDeviationCap);
        if (cap == 0) return;

        uint128 oldAnchor = cfg.anchorPrice;
        if (oldAnchor == 0) {
            cfg.anchorPrice = newPrice;
            cfg.anchorTimestamp = ts;
            return;
        }

        // Rotate the anchor forward if the rolling window has expired. The new
        // anchor is the price being accepted *now* (`newPrice`), not the
        // previous push: see the function-level NatSpec for the rationale.
        uint128 newAnchor = oldAnchor;
        uint256 _window = anchorWindow;
        // use the caller-provided `ts` rather than re-reading `block.timestamp`
        // so anchor staleness is measured against the exact same moment used
        // to stamp the push (and trivially within uint40 range).
        if (_window != 0 && uint256(ts) - uint256(cfg.anchorTimestamp) > _window) {
            newAnchor = newPrice;
            cfg.anchorPrice = newAnchor;
            cfg.anchorTimestamp = ts;
            emit AnchorRotated(asset, oldAnchor, newAnchor, ts);
        }

        uint256 dev = _deviationBps(newPrice, newAnchor);
        if (dev > cap) revert CumulativeDeviationExceeded(asset, dev, cap);
    }

    /// @dev Absolute deviation of `a` from `b`, scaled to basis points (1 bps = 0.01%).
    /// @dev INVARIANT: callers MUST ensure `b != 0`. Both current call sites
    ///      satisfy this — `keeperPushPrices` guarantees `oldPrice != 0`
    ///      before entering the per-push breaker, and `_checkAndUpdateAnchor`
    ///      short-circuits when `anchorPrice == 0`. No runtime check is added
    ///      here so this helper stays branch-free on the hot path.
    function _deviationBps(uint128 a, uint128 b) internal pure returns (uint256) {
        uint256 diff = a >= b
            ? uint256(a - b)
            : uint256(b - a);
        return diff * BPS_DENOMINATOR / uint256(b);
    }
}
