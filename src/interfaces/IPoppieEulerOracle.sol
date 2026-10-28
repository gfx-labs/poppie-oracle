// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoppieEulerOracle
/// @notice Price store and state machine for tokenized equities (CONTRACT_SPEC.md section 3.1).
/// @dev Prices are 18-decimal USD per one whole token (`10 ** decimals` base units).
///      The ABI push takes `uint128` prices; the packed push carries `uint96` (about 7.9e10 USD per token at
///      18 decimals), and both go through the same internal function.
///      Roles: `K_PRICE`, `K_CONFIRM`, `MS_OPS` (listing, unpause, risk params), and `DEFAULT_ADMIN_ROLE`
///      (role holders only).
interface IPoppieEulerOracle {
    /// @notice Price state, derived on every read. `Closed` is the zero value so an unset state fails closed.
    /// @dev Closed: `paused`, or `now - max(lastPriceTs, pendingTs) > maxPriceAge`.
    ///      Unconfirmed: not closed and `pendingCount > 0`. Live: otherwise.
    enum PriceState {
        Closed,
        Unconfirmed,
        Live
    }

    /// @notice Price class. Sets the haircut `h`. Separate from the steward's risk class.
    enum PriceClass {
        BlueChip,
        M1,
        M2,
        M3
    }

    /// @notice Full per-asset record, hot slot first, then the pending slot.
    /// @dev Hot slot (written on every push): 16+5+1+1+1+1+1+1+2 = 29 bytes. Pending slot: 16+5 bytes.
    struct AssetData {
        uint128 lastPrice; // last confirmed price; 0 means never confirmed
        uint40 lastPriceTs;
        uint8 pendingCount;
        int8 pendingDir; // +1 or -1; 0 when nothing is pending
        bool paused;
        PriceClass priceClass;
        uint8 decimals; // of the underlying token, <= 18
        bool listed;
        uint16 id; // compact id used by keeperPushPacked
        uint128 pendingPrice;
        uint40 pendingTs;
    }

    /// @notice Everything the adapter and the escrow hook need, in one call.
    struct QuoteData {
        PriceState state;
        uint128 lastPrice; // `L`
        uint128 pendingPrice; // `P`; 0 unless a move is pending
        uint16 haircutBps; // `h` of the asset's price class
        uint8 decimals;
    }

    // -- Events ---------------------------------------------------------------------------------

    event AssetListed(address indexed asset, uint16 indexed id, PriceClass priceClass, uint8 decimals);
    /// @notice A push within the bound, or a promotion, set the live price.
    event PriceLive(address indexed asset, uint128 price);
    event PricePending(address indexed asset, uint128 price, uint8 count, int8 dir);
    event PriceConfirmed(address indexed asset, uint128 price, address indexed by);
    /// @notice `n` correctly spaced same-direction pushes took a pending price live.
    event PricePromotedByPersistence(address indexed asset, uint128 price);
    event AssetPaused(address indexed asset, address indexed by);
    event AssetUnpaused(address indexed asset, address indexed by);
    event ParamsUpdated(uint40 maxPriceAge, uint8 n, uint40 minPendingSpacing);
    event AssetClassSet(address indexed asset, PriceClass priceClass);
    event ClassHaircutSet(PriceClass indexed priceClass, uint16 haircutBps);

    // -- Errors ---------------------------------------------------------------------------------

    error ZeroAddress();
    error LengthMismatch();
    error AssetNotListed(address asset);
    error AssetAlreadyListed(address asset);
    error TooManyAssets();
    error DecimalsTooHigh(uint8 decimals);
    error AssetIsPaused(address asset);
    error InvalidPrice();
    /// @dev Packed payload length is not a multiple of 14.
    error InvalidPackedLength(uint256 length);
    error UnknownAssetId(uint16 id);
    error NothingPending(address asset);
    error PendingPriceMismatch(address asset, uint128 pending, uint128 given);
    error PendingPriceStale(address asset);
    /// @dev `n` must be >= 2; `maxPriceAge` and `minPendingSpacing` non-zero; haircut <= 10_000 bps.
    error InvalidParam();

    // -- Keeper (K_PRICE) -----------------------------------------------------------------------

    /// @notice Push prices. Role `K_PRICE`. Reverts for a paused asset. See CONTRACT_SPEC.md 3.1 for the rules.
    function keeperPushPrices(address[] calldata assets, uint128[] calldata prices) external;

    /// @notice Same logic through the same internal function, in the packed format: 14 bytes per entry,
    /// `uint16 id | uint96 price`, big-endian, no length prefix (`abi.encodePacked(uint16, uint96)`).
    /// Role `K_PRICE`.
    function keeperPushPacked(bytes calldata data) external;

    /// @notice Pause assets, keeping `lastPrice`. Roles `K_PRICE` or `MS_OPS`.
    function pauseAssets(address[] calldata assets) external;

    // -- Confirmation (K_CONFIRM) ---------------------------------------------------------------

    /// @notice Promote the pending price to live. Role `K_CONFIRM`. Requires the asset not paused,
    /// `pendingCount > 0`, `price == pendingPrice` and `now - pendingTs <= maxPriceAge`.
    function confirm(address asset, uint128 price) external;

    /// @notice `confirm` for each entry, all-or-nothing. Role `K_CONFIRM`.
    function confirmBatch(address[] calldata assets, uint128[] calldata prices) external;

    // -- Ops (MS_OPS) ---------------------------------------------------------------------------

    /// @notice Add-only listing of underlying tokens (never wrappers). Assigns ids, reads `decimals()` (<= 18).
    /// Role `MS_OPS`.
    function listAssets(address[] calldata tokens, PriceClass[] calldata classes) external;

    /// @notice Clear `paused`. Role `MS_OPS`.
    function unpauseAssets(address[] calldata assets) external;

    // -- Risk params (MS_OPS, instant) ----------------------------------------------------------
    // Risk params carry no timelock (like steward overrides and cap ceilings); only the hard bounds below
    // apply. Role holders stay with `DEFAULT_ADMIN_ROLE` (timelock).

    function setAssetClass(address asset, PriceClass priceClass) external;
    /// @dev Reverts `InvalidParam` if `newHaircutBps > 10_000`.
    function setClassHaircut(PriceClass priceClass, uint16 newHaircutBps) external;
    /// @dev Reverts `InvalidParam` if zero.
    function setMaxPriceAge(uint40 newMaxPriceAge) external;
    /// @dev Reverts `InvalidParam` if `newN < 2`.
    function setN(uint8 newN) external;
    /// @dev Reverts `InvalidParam` if zero.
    function setMinPendingSpacing(uint40 newMinPendingSpacing) external;

    // -- Views ----------------------------------------------------------------------------------

    /// @notice Derived price state. Reverts `AssetNotListed`.
    function state(address asset) external view returns (PriceState);

    function getAssetData(address asset) external view returns (AssetData memory);

    /// @notice State, `L`, `P`, `h` and decimals in one call. Used by the adapter and the escrow hook.
    /// Reverts `AssetNotListed`.
    function getQuoteData(address asset) external view returns (QuoteData memory);

    /// @notice Batch views for monitoring.
    function getStates(address[] calldata assets) external view returns (PriceState[] memory);
    function getQuoteDataBatch(address[] calldata assets) external view returns (QuoteData[] memory);

    function isListed(address asset) external view returns (bool);
    function assetId(address asset) external view returns (uint16);
    function assetById(uint16 id) external view returns (address);
    function assetCount() external view returns (uint256);

    function maxPriceAge() external view returns (uint40);
    function n() external view returns (uint8);
    function minPendingSpacing() external view returns (uint40);
    function haircutBps(PriceClass priceClass) external view returns (uint16);
}
