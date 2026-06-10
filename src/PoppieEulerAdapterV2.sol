// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";
import {IPoppieEulerOracleV2} from "./interfaces/IPoppieEulerOracleV2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title IERC20Decimals
/// @notice Minimal interface to read token decimals.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title PoppieEulerAdapterV2
/// @notice Euler-compatible oracle adapter for Ondo tokenized assets. Implements
///         IPriceOracle and reads validated 18-decimal prices from PoppieEulerOracleV2.
/// @dev    This is a multi-asset singleton: one adapter serves every registered Ondo
///         token against a single unit of account. The Euler Oracle Router registers
///         this adapter for each (ondoToken, unitOfAccount) pair.
///
///         Unlike the per-pair adapters in euler-price-oracle (which fix `base` as an
///         immutable and reject any other base via getDirectionOrRevert), this adapter
///         supports many bases. To preserve the same guarantee that an unconfigured or
///         mis-decimaled base can never be priced, every base must be explicitly
///         registered by the admin before it can be quoted. Registration caches the
///         base's decimals so the conversion never depends on a live, untrusted
///         `decimals()` call at quote time.
///
///         Staleness: `getQuote` reads `master.getPrice(base)`, which reverts when the
///         stored price is older than the oracle's `maxPriceAge`. This is intentional —
///         it causes Euler account-status checks (including liquidations) to revert
///         until a fresh price is written, rather than transacting on a stale price.
contract PoppieEulerAdapterV2 is IPriceOracle {
    /// @notice The PoppieEulerOracle that stores validated prices at 18 decimals.
    IPoppieEulerOracleV2 public immutable master;

    /// @notice The unit of account (quote) this adapter prices into.
    address public immutable unitOfAccount;

    /// @notice The decimals of the unit of account (e.g. 18 for USDT on BSC).
    uint8 public immutable unitOfAccountDecimals;

    /// @notice Admin that may register supported base tokens.
    address public admin;

    /// @notice Per-base registration record. `registered` gates pricing; `decimals`
    ///         is the cached decimals of the base token used in the conversion.
    struct BaseInfo {
        bool registered;
        uint8 decimals;
    }

    mapping(address => BaseInfo) internal _baseInfo;

    event AdminUpdated(address oldAdmin, address newAdmin);
    event BaseRegistered(address indexed base, uint8 decimals);
    event BaseDecimalsUpdated(address indexed base, uint8 oldDecimals, uint8 newDecimals);
    event BaseUnregistered(address indexed base);

    /// @notice Emitted once at deployment so indexers can discover a new adapter and
    ///         its immutable configuration (master, unit of account) and initial admin
    ///         from logs alone, without out-of-band knowledge of the address.
    event AdapterDeployed(
        address indexed master,
        address indexed unitOfAccount,
        uint8 unitOfAccountDecimals,
        address admin
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "PoppieEulerAdapter: only admin");
        _;
    }

    /// @param _master The PoppieEulerOracleV2 price store.
    /// @param _admin The admin allowed to register base tokens.
    /// @param _unitOfAccount The quote asset this adapter prices into.
    /// @param _unitOfAccountDecimals The decimals of the unit of account.
    constructor(
        address _master,
        address _admin,
        address _unitOfAccount,
        uint8 _unitOfAccountDecimals
    ) {
        require(_master != address(0), "PoppieEulerAdapter: zero master");
        require(_admin != address(0), "PoppieEulerAdapter: zero admin");
        require(_unitOfAccount != address(0), "PoppieEulerAdapter: zero unit of account");
        // Bounding the unit-of-account decimals to <= 18 guarantees that, combined with
        // the base decimals cap (also <= 18), the conversion exponent
        // (baseDecimals + 18 - unitOfAccountDecimals) is always non-negative, so the
        // divide-only path in _computeQuote can never underflow.
        require(_unitOfAccountDecimals <= 18, "PoppieEulerAdapter: unit decimals too large");

        master = IPoppieEulerOracleV2(_master);
        admin = _admin;
        unitOfAccount = _unitOfAccount;
        unitOfAccountDecimals = _unitOfAccountDecimals;

        emit AdapterDeployed(_master, _unitOfAccount, _unitOfAccountDecimals, _admin);
    }

    /// @inheritdoc IPriceOracle
    function name() external pure override returns (string memory) {
        return "PoppieEulerAdapterV2";
    }

    // --- Admin ---

    /// @notice Register a new base token so it can be priced. Reads and caches the
    ///         base's `decimals()` at registration; the cached value is used for all
    ///         future conversions so pricing never depends on a live `decimals()` call.
    /// @dev    Reverts if the base is already registered. Changing the decimals of a
    ///         live base is a deliberate, separate action — use `updateBaseDecimals`.
    function registerBase(address base) external onlyAdmin {
        require(base != address(0), "PoppieEulerAdapter: zero base");
        require(!_baseInfo[base].registered, "PoppieEulerAdapter: base already registered");
        uint8 dec = IERC20Decimals(base).decimals();
        require(dec <= 18, "PoppieEulerAdapter: decimals too large");
        _baseInfo[base] = BaseInfo({registered: true, decimals: dec});
        emit BaseRegistered(base, dec);
    }

    /// @notice Register a new base token with an explicitly supplied decimals value,
    ///         for tokens that do not implement a reliable `decimals()`.
    /// @dev    Reverts if the base is already registered.
    function registerBaseWithDecimals(address base, uint8 decimals) external onlyAdmin {
        require(base != address(0), "PoppieEulerAdapter: zero base");
        require(!_baseInfo[base].registered, "PoppieEulerAdapter: base already registered");
        require(decimals <= 18, "PoppieEulerAdapter: decimals too large");
        _baseInfo[base] = BaseInfo({registered: true, decimals: decimals});
        emit BaseRegistered(base, decimals);
    }

    /// @notice Update the cached decimals of an already-registered base.
    /// @dev    Deliberately separate from registration so the decimals of a live base
    ///         can only change through an explicit, intentional call. Mis-setting this
    ///         mis-values the base in Euler, so use with care.
    function updateBaseDecimals(address base, uint8 decimals) external onlyAdmin {
        require(_baseInfo[base].registered, "PoppieEulerAdapter: base not registered");
        require(decimals <= 18, "PoppieEulerAdapter: decimals too large");
        uint8 oldDecimals = _baseInfo[base].decimals;
        _baseInfo[base].decimals = decimals;
        emit BaseDecimalsUpdated(base, oldDecimals, decimals);
    }

    /// @notice Remove a base token. After this, quotes for the base revert.
    function unregisterBase(address base) external onlyAdmin {
        delete _baseInfo[base];
        emit BaseUnregistered(base);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "PoppieEulerAdapter: zero admin");
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Returns whether a base is registered and its cached decimals.
    function getBaseInfo(address base) external view returns (bool registered, uint8 decimals) {
        BaseInfo storage info = _baseInfo[base];
        return (info.registered, info.decimals);
    }

    // --- Pricing ---

    /// @notice Returns how much `quote` you get for `inAmount` of `base`.
    /// @dev    The Euler Oracle Router calls this with base=ondoToken, quote=unitOfAccount.
    ///         Reverts if `quote` is not the configured unit of account or if `base` is
    ///         not registered. A return of 0 for a tiny `inAmount` is valid per the spec.
    /// @inheritdoc IPriceOracle
    function getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) external view override returns (uint256 outAmount) {
        require(quote == unitOfAccount, "PoppieEulerAdapter: unsupported quote");
        outAmount = _computeQuote(inAmount, base);
    }

    /// @notice Bid and ask are identical -- this is a validated-price oracle with no spread.
    /// @inheritdoc IPriceOracle
    function getQuotes(
        uint256 inAmount,
        address base,
        address quote
    ) external view override returns (uint256 bidOutAmount, uint256 askOutAmount) {
        require(quote == unitOfAccount, "PoppieEulerAdapter: unsupported quote");
        uint256 amount = _computeQuote(inAmount, base);
        bidOutAmount = amount;
        askOutAmount = amount;
    }

    /// @notice Compute the output amount of unitOfAccount for a given inAmount of base.
    /// @dev    Uses the decimals cached at registration, not a live `decimals()` call.
    ///         price is 18-decimal USD per whole token (e.g. $175.23 = 175.23e18).
    ///
    ///         outAmount = inAmount * price * 10^quoteDecimals / (10^baseDecimals * 10^18)
    ///                   = inAmount * price / 10^(baseDecimals + 18 - quoteDecimals)
    ///
    ///         The exponent is always non-negative: baseDecimals <= 18 (enforced at
    ///         registration) and unitOfAccountDecimals <= 18 (enforced in the
    ///         constructor), so baseDecimals + 18 - unitOfAccountDecimals >= 0.
    ///
    ///         `Math.mulDiv` performs the multiply-then-divide with a 512-bit
    ///         intermediate, so `inAmount * price` can never overflow uint256 even for
    ///         very large positions / high prices.
    function _computeQuote(uint256 inAmount, address base) internal view returns (uint256) {
        if (inAmount == 0) return 0;

        BaseInfo storage info = _baseInfo[base];
        require(info.registered, "PoppieEulerAdapter: base not registered");

        int256 price = master.getPrice(base); // reverts if uninitialized or stale
        require(price > 0, "PoppieEulerAdapter: invalid price");

        // Safe: info.decimals <= 18 and unitOfAccountDecimals <= 18, so >= 0.
        uint256 denominatorExp = uint256(info.decimals) + 18 - uint256(unitOfAccountDecimals);
        return Math.mulDiv(inAmount, uint256(price), 10 ** denominatorExp);
    }
}
