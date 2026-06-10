// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoppieEulerOracleV2} from "./interfaces/IPoppieEulerOracleV2.sol";

/// @title PoppieEulerOracleV2
/// @notice Singleton that stores validated prices for all Ondo assets at
///         18-decimal precision for Euler's amount-based IPriceOracle interface,
///         read by PoppieEulerAdapter via `getPrice`.
///
/// @dev    Price flow: the keeper computes each price off-chain (Hermes price
///         times the per-asset shares multiplier) and submits the final 18-decimal
///         value through `keeperPushPrices`. The shares multiplier is applied
///         entirely off-chain; this contract stores and serves the final price.
///         Each push is bounded by the per-asset circuit breaker.
///
/// @dev    Read freshness: `getPrice` reverts when the stored price is older than
///         `maxPriceAge`. Because PoppieEulerAdapter reads through `getPrice`,
///         every Euler account-status check (borrow, withdraw-with-debt,
///         liquidation) refuses to operate on a stale price. For tokenized
///         equities this is intentional — off-hours marks are weak signal and
///         off-hours liquidity is poor, so the protocol holds still until a fresh
///         price is written. `maxPriceAge` is admin-settable so it can be widened
///         during an incident without redeploy.
///
/// @dev    Large-move recovery: the circuit breaker blocks the keeper from pushing
///         a move larger than the per-asset threshold. For a legitimate large move
///         (earnings gap, halt and reopen, uncaught split) the keeper therefore
///         cannot push, the price goes stale, and the freshness guard freezes the
///         asset in Euler. `adminSetPrice` / `adminSetPrices` is the recovery
///         lever: it writes `lastPrice` and `lastPriceTimestamp` directly,
///         bypassing the circuit breaker, which both injects the post-move price
///         and refreshes the staleness clock in a single call. It does not change
///         the breaker threshold, so the keeper's next push is re-validated
///         against the new price.
///
/// @dev    Trust model: `lastPriceTimestamp` is the time the keeper (or admin)
///         wrote the price on-chain, not a cryptographically attested publish
///         time. `maxPriceAge` bounds how stale a stored price may be but does not
///         prevent a compromised keeper from writing an off-market price with a
///         fresh timestamp.
contract PoppieEulerOracleV2 is IPoppieEulerOracleV2 {
    // --- State ---

    mapping(address => AssetConfig) internal _assetConfigs;

    address public override admin;
    address public override keeper;

    /// @notice Maximum age (seconds) of a stored price before `getPrice` reverts.
    ///         Admin-settable; default 3600 (1 hour). A value of 0 disables the
    ///         guard so reads never revert on age — an escape hatch not intended
    ///         for normal operation.
    uint256 public override maxPriceAge;

    // --- Modifiers ---

    modifier onlyAdmin() {
        require(msg.sender == admin, "PoppieEulerOracle: only admin");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper, "PoppieEulerOracle: only keeper");
        _;
    }

    // --- Constructor ---

    constructor(address _admin, address _keeper, uint256 _maxPriceAge) {
        require(_admin != address(0), "PoppieEulerOracle: zero admin");
        require(_keeper != address(0), "PoppieEulerOracle: zero keeper");

        admin = _admin;
        keeper = _keeper;
        maxPriceAge = _maxPriceAge; // intended: 3600 (1 hour)

        emit OracleDeployed(_admin, _keeper, _maxPriceAge);
    }

    // --- View Functions ---

    /// @notice Returns the last validated price for the asset at 18 decimals
    ///         (e.g. $175.23 is 175_230000000000000000).
    /// @dev    Reverts if the stored price is older than `maxPriceAge`. This guard
    ///         makes every Euler account-status check (borrow, withdraw-with-debt,
    ///         liquidation) refuse to operate on a stale price. The internal
    ///         circuit-breaker comparison reads the stored field directly rather
    ///         than through this function, so it is not subject to the guard.
    function getPrice(address asset) external view override returns (int256) {
        AssetConfig storage config = _assetConfigs[asset];
        int256 price = config.lastPrice;
        require(price != 0, "PoppieEulerOracle: price not initialized");

        if (maxPriceAge != 0) {
            require(
                block.timestamp - config.lastPriceTimestamp <= maxPriceAge,
                "PoppieEulerOracle: stale price"
            );
        }

        return price;
    }

    function getAssetConfig(address asset) external view override returns (AssetConfig memory) {
        return _assetConfigs[asset];
    }

    // --- Keeper Functions ---

    /// @notice Keeper-only. Pushes pre-computed prices. The keeper fetches prices
    ///         from Hermes, applies the shares multiplier off-chain, and submits
    ///         final 18-decimal USD prices here. The per-asset circuit breaker
    ///         applies to each price.
    function keeperPushPrices(
        address[] calldata assets,
        int256[] calldata prices
    ) external override onlyKeeper {
        require(assets.length == prices.length, "PoppieEulerOracle: length mismatch");

        for (uint256 i = 0; i < assets.length; i++) {
            require(prices[i] > 0, "PoppieEulerOracle: invalid price");
            require(
                _assetConfigs[assets[i]].configured,
                "PoppieEulerOracle: asset not configured"
            );

            // Circuit breaker: reject moves larger than the per-asset threshold
            int256 oldPrice = _assetConfigs[assets[i]].lastPrice;
            if (oldPrice != 0) {
                uint256 deviation = _absDiff(prices[i], oldPrice) * 10000 / _abs(oldPrice);
                uint256 threshold = _assetConfigs[assets[i]].circuitBreakerThreshold;
                if (threshold > 0) {
                    require(
                        deviation <= threshold,
                        "PoppieEulerOracle: circuit breaker triggered"
                    );
                }
            }

            _assetConfigs[assets[i]].lastPrice = prices[i];
            _assetConfigs[assets[i]].lastPriceTimestamp = block.timestamp;
        }

        emit PricesRefreshed(assets);
    }

    // --- Admin Functions ---

    /// @notice Configures new assets. Reverts if an asset is already configured so a
    ///         live stored price is never wiped. The Pyth feed used to price an asset
    ///         is selected entirely off-chain by the keeper (see oracle.md); this
    ///         contract only tracks that an asset is configured and its circuit-breaker
    ///         threshold.
    function configureAssets(
        address[] calldata assets,
        uint256[] calldata circuitBreakerThresholds
    ) external override onlyAdmin {
        require(
            assets.length == circuitBreakerThresholds.length,
            "PoppieEulerOracle: length mismatch"
        );

        for (uint256 i = 0; i < assets.length; i++) {
            require(
                !_assetConfigs[assets[i]].configured,
                "PoppieEulerOracle: asset already configured"
            );

            _assetConfigs[assets[i]] = AssetConfig({
                configured: true,
                circuitBreakerThreshold: circuitBreakerThresholds[i],
                lastPrice: 0,
                lastPriceTimestamp: 0
            });

            emit AssetConfigured(assets[i]);
        }
    }

    function setCircuitBreakerThreshold(
        address asset,
        uint256 threshold
    ) external override onlyAdmin {
        _assetConfigs[asset].circuitBreakerThreshold = threshold;
        emit CircuitBreakerThresholdSet(asset, threshold);
    }

    /// @notice Admin force-push recovery (single asset). Writes the price fields
    ///         directly, bypassing the circuit breaker, and refreshes the staleness
    ///         clock. Use when a legitimate price move exceeds the per-asset breaker
    ///         and the keeper therefore cannot push.
    /// @dev    Does not modify the circuit breaker threshold, so the keeper's next
    ///         push is re-validated against the new price.
    function adminSetPrice(address asset, int256 price) external override onlyAdmin {
        _adminSetPrice(asset, price);
    }

    /// @notice Admin force-push recovery (batch). Same semantics as `adminSetPrice`
    ///         applied to each (asset, price) pair.
    function adminSetPrices(
        address[] calldata assets,
        int256[] calldata prices
    ) external override onlyAdmin {
        require(assets.length == prices.length, "PoppieEulerOracle: length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            _adminSetPrice(assets[i], prices[i]);
        }
    }

    /// @notice Admin sets the read-path freshness window (seconds).
    /// @dev    Widen the window during an incident (e.g. a keeper outage during
    ///         market hours) so account-status checks are not frozen, then tighten
    ///         it afterward. Setting 0 disables the guard. Intentionally has no
    ///         timelock so it can be used as an incident-response lever.
    function setMaxPriceAge(uint256 newMaxPriceAge) external override onlyAdmin {
        emit MaxPriceAgeUpdated(maxPriceAge, newMaxPriceAge);
        maxPriceAge = newMaxPriceAge;
    }

    function setKeeper(address newKeeper) external override onlyAdmin {
        require(newKeeper != address(0), "PoppieEulerOracle: zero keeper");
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    function setAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "PoppieEulerOracle: zero admin");
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    // --- Internal ---

    /// @dev Shared force-push logic. Bypasses the circuit breaker, writes the price
    ///      fields, and refreshes staleness.
    function _adminSetPrice(address asset, int256 price) internal {
        require(price > 0, "PoppieEulerOracle: invalid price");
        require(
            _assetConfigs[asset].configured,
            "PoppieEulerOracle: asset not configured"
        );

        _assetConfigs[asset].lastPrice = price;
        _assetConfigs[asset].lastPriceTimestamp = block.timestamp;

        emit AdminPriceForced(asset, price);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }
}
