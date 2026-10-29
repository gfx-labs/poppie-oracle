// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {MS_OPS, K_PRICE, K_CONFIRM} from "../access/Roles.sol";
import {IPoppieEulerOracle} from "../interfaces/IPoppieEulerOracle.sol";
import {PackedPrices} from "./PackedPrices.sol";

/// @title PoppieEulerOracle
/// @notice Price store and state machine for tokenized equities (CONTRACT_SPEC.md section 3.1, V2_PLAN.md
/// section 1).
/// @dev Storage: two slots per asset (hot slot written on every push, pending slot written only while a move is
/// pending) and one global slot. Both push formats go through `_pushOne`.
///
/// State machine for a push `p` with `L = lastPrice` and `h` the haircut of the asset's price class:
///  1. `L == 0`: always pending (count 1, refreshed on every push). Only `confirm` takes it live.
///  2. `|p - L| <= h * L`: live at once, pending cleared.
///  3. otherwise, with `dir = sign(p - L)`: a push inside `minPendingSpacing` of the last pending push is ignored;
///     else same direction increments the count and a new direction restarts it at 1; `count >= n` promotes.
///
/// Listing takes underlying tokens only, never wrappers (the escrow vault holds the wrapper; the router resolves it
/// to the underlying token before it reaches the adapter). This is a listing rule for `MS_OPS`, not an on-chain
/// check: the oracle only verifies what a token exposes (non-zero address, `decimals() <= 18`, not yet listed).
///
/// Asset ids are sequential and start at 1; id 0 is never assigned and is rejected by the packed push.
/// `ZeroAddress` comes from the interface; `PoppieAccessControl` reverts with the shared file-level error of
/// `access/Errors.sol`, which has the same selector.
contract PoppieEulerOracle is IPoppieEulerOracle, PoppieAccessControl {
    /// @dev Hot slot, 29 bytes. Same field order as the first part of `IPoppieEulerOracle.AssetData`.
    struct Hot {
        uint128 lastPrice;
        uint40 lastPriceTs;
        uint8 pendingCount;
        int8 pendingDir;
        bool paused;
        PriceClass priceClass;
        uint8 decimals;
        bool listed;
        uint16 id;
    }

    /// @dev Pending slot, 21 bytes. Zero whenever `Hot.pendingCount == 0`.
    struct Pending {
        uint128 pendingPrice;
        uint40 pendingTs;
    }

    /// @dev The single global slot: 5 + 1 + 5 + 4 * 2 = 19 bytes.
    struct Params {
        uint40 maxPriceAge;
        uint8 n;
        uint40 minPendingSpacing;
        uint16 hBlueChip;
        uint16 hM1;
        uint16 hM2;
        uint16 hM3;
    }

    uint256 internal constant BPS = 10_000;

    Params internal _params;
    mapping(address asset => Hot) internal _hot;
    mapping(address asset => Pending) internal _pending;
    /// @dev Listed tokens in listing order: the token with `uint16` id `k` is `_tokens[k - 1]`. Ids are assigned
    /// sequentially from 1 and never reused; id 0 is unassigned.
    address[] internal _tokens;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @dev Defaults from V2_PLAN.md: `maxPriceAge` 1h, `n` 3, `minPendingSpacing` 10 min, haircuts 10/15/20/30%.
    constructor(address initialAdmin) PoppieAccessControl(initialAdmin) {
        _params = Params({
            maxPriceAge: 1 hours, n: 3, minPendingSpacing: 10 minutes, hBlueChip: 1000, hM1: 1500, hM2: 2000, hM3: 3000
        });
        emit ParamsUpdated(1 hours, 3, 10 minutes);
        emit ClassHaircutSet(PriceClass.BlueChip, 1000);
        emit ClassHaircutSet(PriceClass.M1, 1500);
        emit ClassHaircutSet(PriceClass.M2, 2000);
        emit ClassHaircutSet(PriceClass.M3, 3000);
    }

    // -- Keeper (K_PRICE) -----------------------------------------------------------------------

    function keeperPushPrices(address[] calldata assets, uint128[] calldata prices)
        external
        override
        onlyRole(K_PRICE)
    {
        uint256 len = assets.length;
        if (len != prices.length) revert LengthMismatch();
        Params memory g = _params;
        for (uint256 i; i < len;) {
            _pushOne(assets[i], prices[i], g);
            unchecked {
                ++i;
            }
        }
    }

    function keeperPushPacked(bytes calldata data) external override onlyRole(K_PRICE) {
        if (!PackedPrices.isValidLength(data)) revert InvalidPackedLength(data.length);
        uint256 len = PackedPrices.entryCount(data);
        uint256 count = _tokens.length;
        Params memory g = _params;
        for (uint256 i; i < len;) {
            (uint16 id, uint96 price) = PackedPrices.decode(data, i);
            // Ids start at 1; id `k` is `_tokens[k - 1]`. Id 0 is never assigned.
            if (id == 0 || id > count) revert UnknownAssetId(id);
            _pushOne(_tokens[id - 1], price, g);
            unchecked {
                ++i;
            }
        }
    }

    function pauseAssets(address[] calldata assets) external override {
        if (!hasRole(K_PRICE, msg.sender) && !hasRole(MS_OPS, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, K_PRICE);
        }
        for (uint256 i; i < assets.length;) {
            address asset = assets[i];
            Hot memory h = _hot[asset];
            if (!h.listed) revert AssetNotListed(asset);
            if (!h.paused) {
                h.paused = true;
                _hot[asset] = h;
                emit AssetPaused(asset, msg.sender);
            }
            unchecked {
                ++i;
            }
        }
    }

    // -- Confirmation (K_CONFIRM) ---------------------------------------------------------------

    function confirm(address asset, uint128 price) external override onlyRole(K_CONFIRM) {
        _confirm(asset, price, _params.maxPriceAge);
    }

    function confirmBatch(address[] calldata assets, uint128[] calldata prices) external override onlyRole(K_CONFIRM) {
        uint256 len = assets.length;
        if (len != prices.length) revert LengthMismatch();
        uint40 maxAge = _params.maxPriceAge;
        for (uint256 i; i < len;) {
            _confirm(assets[i], prices[i], maxAge);
            unchecked {
                ++i;
            }
        }
    }

    // -- Ops (MS_OPS) ---------------------------------------------------------------------------

    /// @dev The oracle can only check what a token exposes: non-zero address, `decimals()` <= 18, not already
    /// listed. That the token is the underlying and not a wrapper is a listing rule enforced by the `MS_OPS`
    /// process and downstream by `PoppieRouterGovernor.addRoute` (approved tokens only).
    function listAssets(address[] calldata tokens, PriceClass[] calldata classes) external override onlyRole(MS_OPS) {
        uint256 len = tokens.length;
        if (len != classes.length) revert LengthMismatch();
        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (_hot[token].listed) revert AssetAlreadyListed(token);
            // The next id is `count + 1`; the last assignable id is `type(uint16).max`.
            uint256 nextId = _tokens.length + 1;
            if (nextId > type(uint16).max) revert TooManyAssets();
            uint8 dec = IERC20Metadata(token).decimals();
            if (dec > 18) revert DecimalsTooHigh(dec);
            // casting to 'uint16' is safe because `nextId <= type(uint16).max` was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 id = uint16(nextId);
            _hot[token] = Hot({
                lastPrice: 0,
                lastPriceTs: 0,
                pendingCount: 0,
                pendingDir: 0,
                paused: false,
                priceClass: classes[i],
                decimals: dec,
                listed: true,
                id: id
            });
            _tokens.push(token);
            emit AssetListed(token, id, classes[i], dec);
            unchecked {
                ++i;
            }
        }
    }

    function unpauseAssets(address[] calldata assets) external override onlyRole(MS_OPS) {
        for (uint256 i; i < assets.length;) {
            address asset = assets[i];
            Hot memory h = _hot[asset];
            if (!h.listed) revert AssetNotListed(asset);
            if (h.paused) {
                h.paused = false;
                _hot[asset] = h;
                emit AssetUnpaused(asset, msg.sender);
            }
            unchecked {
                ++i;
            }
        }
    }

    // -- Risk params (MS_OPS, instant) ----------------------------------------------------------

    function setAssetClass(address asset, PriceClass priceClass) external override onlyRole(MS_OPS) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert AssetNotListed(asset);
        h.priceClass = priceClass;
        _hot[asset] = h;
        emit AssetClassSet(asset, priceClass);
    }

    function setClassHaircut(PriceClass priceClass, uint16 newHaircutBps) external override onlyRole(MS_OPS) {
        if (newHaircutBps > BPS) revert InvalidParam();
        Params memory g = _params;
        if (priceClass == PriceClass.BlueChip) g.hBlueChip = newHaircutBps;
        else if (priceClass == PriceClass.M1) g.hM1 = newHaircutBps;
        else if (priceClass == PriceClass.M2) g.hM2 = newHaircutBps;
        else g.hM3 = newHaircutBps;
        _params = g;
        emit ClassHaircutSet(priceClass, newHaircutBps);
    }

    function setMaxPriceAge(uint40 newMaxPriceAge) external override onlyRole(MS_OPS) {
        if (newMaxPriceAge == 0) revert InvalidParam();
        _params.maxPriceAge = newMaxPriceAge;
        emit ParamsUpdated(newMaxPriceAge, _params.n, _params.minPendingSpacing);
    }

    function setN(uint8 newN) external override onlyRole(MS_OPS) {
        if (newN < 2) revert InvalidParam();
        _params.n = newN;
        emit ParamsUpdated(_params.maxPriceAge, newN, _params.minPendingSpacing);
    }

    function setMinPendingSpacing(uint40 newMinPendingSpacing) external override onlyRole(MS_OPS) {
        if (newMinPendingSpacing == 0) revert InvalidParam();
        _params.minPendingSpacing = newMinPendingSpacing;
        emit ParamsUpdated(_params.maxPriceAge, _params.n, newMinPendingSpacing);
    }

    // -- Views ----------------------------------------------------------------------------------

    function state(address asset) external view override returns (PriceState) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert AssetNotListed(asset);
        (PriceState s,) = _derive(asset, h, _params.maxPriceAge);
        return s;
    }

    /// @dev An unlisted asset returns the zero record (`listed == false`).
    function getAssetData(address asset) external view override returns (AssetData memory d) {
        Hot memory h = _hot[asset];
        Pending memory p = _pending[asset];
        d = AssetData({
            lastPrice: h.lastPrice,
            lastPriceTs: h.lastPriceTs,
            pendingCount: h.pendingCount,
            pendingDir: h.pendingDir,
            paused: h.paused,
            priceClass: h.priceClass,
            decimals: h.decimals,
            listed: h.listed,
            id: h.id,
            pendingPrice: p.pendingPrice,
            pendingTs: p.pendingTs
        });
    }

    function getQuoteData(address asset) external view override returns (QuoteData memory) {
        return _quoteData(asset, _params);
    }

    function getStates(address[] calldata assets) external view override returns (PriceState[] memory states) {
        states = new PriceState[](assets.length);
        uint40 maxAge = _params.maxPriceAge;
        for (uint256 i; i < assets.length;) {
            Hot memory h = _hot[assets[i]];
            if (!h.listed) revert AssetNotListed(assets[i]);
            (states[i],) = _derive(assets[i], h, maxAge);
            unchecked {
                ++i;
            }
        }
    }

    function getQuoteDataBatch(address[] calldata assets) external view override returns (QuoteData[] memory data) {
        data = new QuoteData[](assets.length);
        Params memory g = _params;
        for (uint256 i; i < assets.length;) {
            data[i] = _quoteData(assets[i], g);
            unchecked {
                ++i;
            }
        }
    }

    function isListed(address asset) external view override returns (bool) {
        return _hot[asset].listed;
    }

    function assetId(address asset) external view override returns (uint16) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert AssetNotListed(asset);
        return h.id;
    }

    function assetById(uint16 id) external view override returns (address) {
        if (id == 0 || id > _tokens.length) revert UnknownAssetId(id);
        return _tokens[id - 1];
    }

    function assetCount() external view override returns (uint256) {
        return _tokens.length;
    }

    function maxPriceAge() external view override returns (uint40) {
        return _params.maxPriceAge;
    }

    function n() external view override returns (uint8) {
        return _params.n;
    }

    function minPendingSpacing() external view override returns (uint40) {
        return _params.minPendingSpacing;
    }

    function haircutBps(PriceClass priceClass) external view override returns (uint16) {
        return _haircut(_params, priceClass);
    }

    // -- Internals ------------------------------------------------------------------------------

    function _haircut(Params memory g, PriceClass c) internal pure returns (uint16) {
        // Ordered comparisons on the enum's ordinal (BlueChip = 0, M1, M2, M3).
        uint8 k = uint8(c);
        if (k < 1) return g.hBlueChip;
        if (k < 2) return g.hM1;
        if (k < 3) return g.hM2;
        return g.hM3;
    }

    /// @dev State and pending price of a listed asset. The pending slot is read only while a move is pending
    /// (it is zero otherwise, so `max(lastPriceTs, pendingTs)` is just `lastPriceTs`).
    function _derive(address asset, Hot memory h, uint40 maxAge)
        internal
        view
        returns (PriceState s, uint128 pendingPrice)
    {
        uint256 touched = h.lastPriceTs;
        if (h.pendingCount != 0) {
            Pending memory p = _pending[asset];
            pendingPrice = p.pendingPrice;
            if (p.pendingTs > touched) touched = p.pendingTs;
        }
        if (h.paused || block.timestamp - touched > maxAge) {
            return (PriceState.Closed, pendingPrice);
        }
        return (h.pendingCount != 0 ? PriceState.Unconfirmed : PriceState.Live, pendingPrice);
    }

    function _quoteData(address asset, Params memory g) internal view returns (QuoteData memory q) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert AssetNotListed(asset);
        (q.state, q.pendingPrice) = _derive(asset, h, g.maxPriceAge);
        q.lastPrice = h.lastPrice;
        q.haircutBps = _haircut(g, h.priceClass);
        q.decimals = h.decimals;
    }

    /// @dev The one push routine behind both formats. Writes the hot slot once and the pending slot only when a
    /// move starts, continues, or ends.
    function _pushOne(address asset, uint128 p, Params memory g) internal {
        Hot memory h = _hot[asset];
        if (!h.listed) revert AssetNotListed(asset);
        if (h.paused) revert AssetIsPaused(asset);
        if (p == 0) revert InvalidPrice();

        uint256 last = h.lastPrice;
        uint40 nowTs = uint40(block.timestamp);

        // 1. No confirmed price yet: always pending, only `confirm` can take it live.
        if (last < 1) {
            h.pendingCount = 1;
            h.pendingDir = 1;
            _hot[asset] = h;
            _pending[asset] = Pending({pendingPrice: p, pendingTs: nowTs});
            emit PricePending(asset, p, 1, 1);
            return;
        }

        // 2. Within the class bound: live, any pending move is dropped.
        uint256 diff = p > last ? p - last : last - p;
        if (diff * BPS <= uint256(_haircut(g, h.priceClass)) * last) {
            h.lastPrice = p;
            h.lastPriceTs = nowTs;
            if (h.pendingCount != 0) {
                h.pendingCount = 0;
                h.pendingDir = 0;
                delete _pending[asset];
            }
            _hot[asset] = h;
            emit PriceLive(asset, p);
            return;
        }

        // 3. Beyond the bound.
        int8 dir = p > last ? int8(1) : int8(-1);
        uint8 count = 1;
        if (h.pendingCount != 0) {
            // Too soon after the last pending push: ignored, no state change.
            if (block.timestamp < uint256(_pending[asset].pendingTs) + g.minPendingSpacing) return;
            // `pendingDir` is +1 or -1 while a move is pending, so the product is +1 for the same direction.
            if (int16(dir) * h.pendingDir > 0) count = h.pendingCount + 1;
        }

        if (count >= g.n) {
            h.lastPrice = p;
            h.lastPriceTs = nowTs;
            h.pendingCount = 0;
            h.pendingDir = 0;
            _hot[asset] = h;
            delete _pending[asset];
            emit PricePromotedByPersistence(asset, p);
            emit PriceLive(asset, p);
        } else {
            h.pendingCount = count;
            h.pendingDir = dir;
            _hot[asset] = h;
            _pending[asset] = Pending({pendingPrice: p, pendingTs: nowTs});
            emit PricePending(asset, p, count, dir);
        }
    }

    function _confirm(address asset, uint128 price, uint40 maxAge) internal {
        Hot memory h = _hot[asset];
        if (!h.listed) revert AssetNotListed(asset);
        if (h.paused) revert AssetIsPaused(asset);
        if (h.pendingCount < 1) revert NothingPending(asset);
        Pending memory p = _pending[asset];
        if (p.pendingPrice != price) revert PendingPriceMismatch(asset, p.pendingPrice, price);
        if (block.timestamp - p.pendingTs > maxAge) revert PendingPriceStale(asset);

        h.lastPrice = price;
        h.lastPriceTs = uint40(block.timestamp);
        h.pendingCount = 0;
        h.pendingDir = 0;
        _hot[asset] = h;
        delete _pending[asset];
        emit PriceConfirmed(asset, price, msg.sender);
        emit PriceLive(asset, price);
    }
}
