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
/// Conforms to `IPoppieEulerOracle` (same functions, events and errors, same selectors) without inheriting it:
/// the interface declares `error ZeroAddress()` and so does `PoppieAccessControl`, and Solidity rejects the same
/// error name from two bases. The two declarations have the same selector, so the ABI is unchanged. Interface
/// types are referenced by qualified name, and the tests exercise every interface function through the
/// interface type.
contract PoppieEulerOracle is PoppieAccessControl {
    /// @dev Hot slot, 29 bytes. Same field order as the first part of `IPoppieEulerOracle.AssetData`.
    struct Hot {
        uint128 lastPrice;
        uint40 lastPriceTs;
        uint8 pendingCount;
        int8 pendingDir;
        bool paused;
        IPoppieEulerOracle.PriceClass priceClass;
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
    /// @dev Index is the `uint16` id; ids are assigned sequentially from 0 and never reused.
    address[] internal _tokens;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @dev Defaults from V2_PLAN.md: `maxPriceAge` 1h, `n` 3, `minPendingSpacing` 10 min, haircuts 10/15/20/30%.
    constructor(address initialAdmin) PoppieAccessControl(initialAdmin) {
        _params = Params({
            maxPriceAge: 1 hours, n: 3, minPendingSpacing: 10 minutes, hBlueChip: 1000, hM1: 1500, hM2: 2000, hM3: 3000
        });
        emit IPoppieEulerOracle.ParamsUpdated(1 hours, 3, 10 minutes);
        emit IPoppieEulerOracle.ClassHaircutSet(IPoppieEulerOracle.PriceClass.BlueChip, 1000);
        emit IPoppieEulerOracle.ClassHaircutSet(IPoppieEulerOracle.PriceClass.M1, 1500);
        emit IPoppieEulerOracle.ClassHaircutSet(IPoppieEulerOracle.PriceClass.M2, 2000);
        emit IPoppieEulerOracle.ClassHaircutSet(IPoppieEulerOracle.PriceClass.M3, 3000);
    }

    // -- Keeper (K_PRICE) -----------------------------------------------------------------------

    function keeperPushPrices(address[] calldata assets, uint128[] calldata prices) external onlyRole(K_PRICE) {
        uint256 len = assets.length;
        if (len != prices.length) revert IPoppieEulerOracle.LengthMismatch();
        Params memory g = _params;
        for (uint256 i; i < len;) {
            _pushOne(assets[i], prices[i], g);
            unchecked {
                ++i;
            }
        }
    }

    function keeperPushPacked(bytes calldata data) external onlyRole(K_PRICE) {
        if (!PackedPrices.isValidLength(data)) revert IPoppieEulerOracle.InvalidPackedLength(data.length);
        uint256 len = PackedPrices.entryCount(data);
        uint256 count = _tokens.length;
        Params memory g = _params;
        for (uint256 i; i < len;) {
            (uint16 id, uint96 price) = PackedPrices.decode(data, i);
            if (id >= count) revert IPoppieEulerOracle.UnknownAssetId(id);
            _pushOne(_tokens[id], price, g);
            unchecked {
                ++i;
            }
        }
    }

    function pauseAssets(address[] calldata assets) external {
        if (!hasRole(K_PRICE, msg.sender) && !hasRole(MS_OPS, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, K_PRICE);
        }
        for (uint256 i; i < assets.length;) {
            address asset = assets[i];
            Hot memory h = _hot[asset];
            if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
            if (!h.paused) {
                h.paused = true;
                _hot[asset] = h;
                emit IPoppieEulerOracle.AssetPaused(asset, msg.sender);
            }
            unchecked {
                ++i;
            }
        }
    }

    // -- Confirmation (K_CONFIRM) ---------------------------------------------------------------

    function confirm(address asset, uint128 price) external onlyRole(K_CONFIRM) {
        _confirm(asset, price, _params.maxPriceAge);
    }

    function confirmBatch(address[] calldata assets, uint128[] calldata prices) external onlyRole(K_CONFIRM) {
        uint256 len = assets.length;
        if (len != prices.length) revert IPoppieEulerOracle.LengthMismatch();
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
    function listAssets(address[] calldata tokens, IPoppieEulerOracle.PriceClass[] calldata classes)
        external
        onlyRole(MS_OPS)
    {
        uint256 len = tokens.length;
        if (len != classes.length) revert IPoppieEulerOracle.LengthMismatch();
        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (_hot[token].listed) revert IPoppieEulerOracle.AssetAlreadyListed(token);
            uint256 idx = _tokens.length;
            if (idx > type(uint16).max) revert IPoppieEulerOracle.TooManyAssets();
            uint8 dec = IERC20Metadata(token).decimals();
            if (dec > 18) revert IPoppieEulerOracle.DecimalsTooHigh(dec);
            // casting to 'uint16' is safe because `idx <= type(uint16).max` was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 id = uint16(idx);
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
            emit IPoppieEulerOracle.AssetListed(token, id, classes[i], dec);
            unchecked {
                ++i;
            }
        }
    }

    function unpauseAssets(address[] calldata assets) external onlyRole(MS_OPS) {
        for (uint256 i; i < assets.length;) {
            address asset = assets[i];
            Hot memory h = _hot[asset];
            if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
            if (h.paused) {
                h.paused = false;
                _hot[asset] = h;
                emit IPoppieEulerOracle.AssetUnpaused(asset, msg.sender);
            }
            unchecked {
                ++i;
            }
        }
    }

    // -- Risk params (MS_OPS, instant) ----------------------------------------------------------

    function setAssetClass(address asset, IPoppieEulerOracle.PriceClass priceClass) external onlyRole(MS_OPS) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
        h.priceClass = priceClass;
        _hot[asset] = h;
        emit IPoppieEulerOracle.AssetClassSet(asset, priceClass);
    }

    function setClassHaircut(IPoppieEulerOracle.PriceClass priceClass, uint16 newHaircutBps) external onlyRole(MS_OPS) {
        if (newHaircutBps > BPS) revert IPoppieEulerOracle.InvalidParam();
        Params memory g = _params;
        if (priceClass == IPoppieEulerOracle.PriceClass.BlueChip) g.hBlueChip = newHaircutBps;
        else if (priceClass == IPoppieEulerOracle.PriceClass.M1) g.hM1 = newHaircutBps;
        else if (priceClass == IPoppieEulerOracle.PriceClass.M2) g.hM2 = newHaircutBps;
        else g.hM3 = newHaircutBps;
        _params = g;
        emit IPoppieEulerOracle.ClassHaircutSet(priceClass, newHaircutBps);
    }

    function setMaxPriceAge(uint40 newMaxPriceAge) external onlyRole(MS_OPS) {
        if (newMaxPriceAge == 0) revert IPoppieEulerOracle.InvalidParam();
        _params.maxPriceAge = newMaxPriceAge;
        emit IPoppieEulerOracle.ParamsUpdated(newMaxPriceAge, _params.n, _params.minPendingSpacing);
    }

    function setN(uint8 newN) external onlyRole(MS_OPS) {
        if (newN < 2) revert IPoppieEulerOracle.InvalidParam();
        _params.n = newN;
        emit IPoppieEulerOracle.ParamsUpdated(_params.maxPriceAge, newN, _params.minPendingSpacing);
    }

    function setMinPendingSpacing(uint40 newMinPendingSpacing) external onlyRole(MS_OPS) {
        if (newMinPendingSpacing == 0) revert IPoppieEulerOracle.InvalidParam();
        _params.minPendingSpacing = newMinPendingSpacing;
        emit IPoppieEulerOracle.ParamsUpdated(_params.maxPriceAge, _params.n, newMinPendingSpacing);
    }

    // -- Views ----------------------------------------------------------------------------------

    function state(address asset) external view returns (IPoppieEulerOracle.PriceState) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
        (IPoppieEulerOracle.PriceState s,) = _derive(asset, h, _params.maxPriceAge);
        return s;
    }

    /// @dev An unlisted asset returns the zero record (`listed == false`).
    function getAssetData(address asset) external view returns (IPoppieEulerOracle.AssetData memory d) {
        Hot memory h = _hot[asset];
        Pending memory p = _pending[asset];
        d = IPoppieEulerOracle.AssetData({
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

    function getQuoteData(address asset) external view returns (IPoppieEulerOracle.QuoteData memory) {
        return _quoteData(asset, _params);
    }

    function getStates(address[] calldata assets)
        external
        view
        returns (IPoppieEulerOracle.PriceState[] memory states)
    {
        states = new IPoppieEulerOracle.PriceState[](assets.length);
        uint40 maxAge = _params.maxPriceAge;
        for (uint256 i; i < assets.length;) {
            Hot memory h = _hot[assets[i]];
            if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(assets[i]);
            (states[i],) = _derive(assets[i], h, maxAge);
            unchecked {
                ++i;
            }
        }
    }

    function getQuoteDataBatch(address[] calldata assets)
        external
        view
        returns (IPoppieEulerOracle.QuoteData[] memory data)
    {
        data = new IPoppieEulerOracle.QuoteData[](assets.length);
        Params memory g = _params;
        for (uint256 i; i < assets.length;) {
            data[i] = _quoteData(assets[i], g);
            unchecked {
                ++i;
            }
        }
    }

    function isListed(address asset) external view returns (bool) {
        return _hot[asset].listed;
    }

    function assetId(address asset) external view returns (uint16) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
        return h.id;
    }

    function assetById(uint16 id) external view returns (address) {
        if (id >= _tokens.length) revert IPoppieEulerOracle.UnknownAssetId(id);
        return _tokens[id];
    }

    function assetCount() external view returns (uint256) {
        return _tokens.length;
    }

    function maxPriceAge() external view returns (uint40) {
        return _params.maxPriceAge;
    }

    function n() external view returns (uint8) {
        return _params.n;
    }

    function minPendingSpacing() external view returns (uint40) {
        return _params.minPendingSpacing;
    }

    function haircutBps(IPoppieEulerOracle.PriceClass priceClass) external view returns (uint16) {
        return _haircut(_params, priceClass);
    }

    // -- Internals ------------------------------------------------------------------------------

    function _haircut(Params memory g, IPoppieEulerOracle.PriceClass c) internal pure returns (uint16) {
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
        returns (IPoppieEulerOracle.PriceState s, uint128 pendingPrice)
    {
        uint256 touched = h.lastPriceTs;
        if (h.pendingCount != 0) {
            Pending memory p = _pending[asset];
            pendingPrice = p.pendingPrice;
            if (p.pendingTs > touched) touched = p.pendingTs;
        }
        if (h.paused || block.timestamp - touched > maxAge) {
            return (IPoppieEulerOracle.PriceState.Closed, pendingPrice);
        }
        return (
            h.pendingCount != 0 ? IPoppieEulerOracle.PriceState.Unconfirmed : IPoppieEulerOracle.PriceState.Live,
            pendingPrice
        );
    }

    function _quoteData(address asset, Params memory g) internal view returns (IPoppieEulerOracle.QuoteData memory q) {
        Hot memory h = _hot[asset];
        if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
        (q.state, q.pendingPrice) = _derive(asset, h, g.maxPriceAge);
        q.lastPrice = h.lastPrice;
        q.haircutBps = _haircut(g, h.priceClass);
        q.decimals = h.decimals;
    }

    /// @dev The one push routine behind both formats. Writes the hot slot once and the pending slot only when a
    /// move starts, continues, or ends.
    function _pushOne(address asset, uint128 p, Params memory g) internal {
        Hot memory h = _hot[asset];
        if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
        if (h.paused) revert IPoppieEulerOracle.AssetIsPaused(asset);
        if (p == 0) revert IPoppieEulerOracle.InvalidPrice();

        uint256 last = h.lastPrice;
        uint40 nowTs = uint40(block.timestamp);

        // 1. No confirmed price yet: always pending, only `confirm` can take it live.
        if (last < 1) {
            h.pendingCount = 1;
            h.pendingDir = 1;
            _hot[asset] = h;
            _pending[asset] = Pending({pendingPrice: p, pendingTs: nowTs});
            emit IPoppieEulerOracle.PricePending(asset, p, 1, 1);
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
            emit IPoppieEulerOracle.PriceLive(asset, p);
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
            emit IPoppieEulerOracle.PricePromotedByPersistence(asset, p);
            emit IPoppieEulerOracle.PriceLive(asset, p);
        } else {
            h.pendingCount = count;
            h.pendingDir = dir;
            _hot[asset] = h;
            _pending[asset] = Pending({pendingPrice: p, pendingTs: nowTs});
            emit IPoppieEulerOracle.PricePending(asset, p, count, dir);
        }
    }

    function _confirm(address asset, uint128 price, uint40 maxAge) internal {
        Hot memory h = _hot[asset];
        if (!h.listed) revert IPoppieEulerOracle.AssetNotListed(asset);
        if (h.paused) revert IPoppieEulerOracle.AssetIsPaused(asset);
        if (h.pendingCount < 1) revert IPoppieEulerOracle.NothingPending(asset);
        Pending memory p = _pending[asset];
        if (p.pendingPrice != price) revert IPoppieEulerOracle.PendingPriceMismatch(asset, p.pendingPrice, price);
        if (block.timestamp - p.pendingTs > maxAge) revert IPoppieEulerOracle.PendingPriceStale(asset);

        h.lastPrice = price;
        h.lastPriceTs = uint40(block.timestamp);
        h.pendingCount = 0;
        h.pendingDir = 0;
        _hot[asset] = h;
        delete _pending[asset];
        emit IPoppieEulerOracle.PriceConfirmed(asset, price, msg.sender);
        emit IPoppieEulerOracle.PriceLive(asset, price);
    }
}
