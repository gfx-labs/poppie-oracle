// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IPriceOracle} from "./vendor/IPriceOracle.sol";
import {IPoppieEulerOracle} from "./interfaces/IPoppieEulerOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal ERC-20 metadata fragment for the optional `decimals()` lookup
///      performed at base registration. We don't import the full OpenZeppelin
///      interface to keep the adapter dependency surface tight.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title PoppieEulerAdapter
/// @author Oku / gfx labs
/// @notice Euler IPriceOracle (ERC-7726) adapter. Multi-asset singleton that
///         converts base token amounts to unitOfAccount using prices from
///         PoppieEulerOracle. Bases must be registered with explicit decimals.
///         Staleness: getQuote reverts if the underlying price is stale.
///
/// @dev    ERC-7726 STATUS — INTEGRATOR NOTICE.
///         ERC-7726 is presently a draft and the EIP itself explicitly notes
///         it should not yet be relied on in production. We implement it
///         because Euler V2's vault layer consumes the interface, but
///         integrators should NOT assume any cross-protocol semantic
///         guarantees from "ERC-7726 compliance" beyond what this contract
///         documents directly:
///           - quote is fixed to the configured `unitOfAccount`,
///           - `getQuote` and `getQuotes` both revert on stale prices,
///           - bid and ask are always identical (no spread model).
///         The underlying oracle (`master`) is the sole source of truth and
///         is the contract that enforces freshness, the circuit breaker, and
///         the cumulative-drift cap. See `IPoppieEulerOracle` for guarantees.
contract PoppieEulerAdapter is IPriceOracle {
    /// @dev maximum decimals for base tokens and unit of account.
    uint8 internal constant MAX_DECIMALS = 18;

    /// @notice The PoppieEulerOracle that stores validated prices at 18 decimals.
    IPoppieEulerOracle public immutable master;
    /// @notice The unit of account (quote) this adapter prices into.
    address public immutable unitOfAccount;
    /// @notice The decimals of the unit of account.
    uint8 public immutable unitOfAccountDecimals;
    /// @notice Admin that may register/unregister base tokens.
    address public admin;
    /// @notice Pending admin for two-step transfer (zero if none).
    address public pendingAdmin;

    /// @notice Per-base registration record.
    struct BaseInfo {
        bool registered;
        uint8 decimals;
    }

    mapping(address => BaseInfo) internal _baseInfo;

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error OnlyAdmin();
    /// @dev Raised by `acceptAdmin` when no pending admin transfer is in flight.
    error NoPendingAdmin();
    /// @dev Raised by `acceptAdmin` when a pending admin transfer is in flight
    ///      but the caller is not the pending admin. Distinguishing this from
    ///      `NoPendingAdmin` lets off-chain monitoring tell a benign
    ///      configuration state apart from an unauthorized take-over attempt.
    error NotPendingAdmin();
    error BaseAlreadyRegistered(address base);
    error BaseNotRegistered(address base);
    error DecimalsTooLarge(uint8 decimals);
    /// @dev Raised by `registerBase` when the caller-supplied decimals do not
    ///      match the value returned by the token's `decimals()`. Tokens that
    ///      do not implement `decimals()` bypass the cross-check.
    error DecimalsMismatch(uint8 supplied, uint8 onChain);
    error UnsupportedQuote(address quote);
    error InvalidPrice();
    error BaseIsUnitOfAccount();
    /// @dev Raised by `registerBase` when the master oracle has no
    ///      configuration entry for the base asset. This catches the common
    ///      typo/ordering failure where the adapter is told to advertise an
    ///      asset that the oracle layer has not been configured to price.
    error OracleNotReady(address base);

    // ── Events ──────────────────────────────────────────────────────────

    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event BaseRegistered(address indexed base, uint8 decimals);
    event BaseUnregistered(address indexed base);
    event AdapterDeployed(address indexed master, address indexed unitOfAccount, uint8 unitOfAccountDecimals, address admin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @param _master The PoppieEulerOracle price store.
    /// @param _admin The admin allowed to register base tokens.
    /// @param _unitOfAccount The quote asset this adapter prices into.
    /// @param _unitOfAccountDecimals The decimals of the unit of account (must be <= 18).
    constructor(address _master, address _admin, address _unitOfAccount, uint8 _unitOfAccountDecimals) {
        if (_master == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_unitOfAccount == address(0)) revert ZeroAddress();
        if (_unitOfAccountDecimals > MAX_DECIMALS) revert DecimalsTooLarge(_unitOfAccountDecimals);
        master = IPoppieEulerOracle(_master);
        admin = _admin;
        unitOfAccount = _unitOfAccount;
        unitOfAccountDecimals = _unitOfAccountDecimals;
        emit AdapterDeployed(_master, _unitOfAccount, _unitOfAccountDecimals, _admin);
    }

    /// @inheritdoc IPriceOracle
    function name() external pure override returns (string memory) {
        return "PoppieEulerAdapter";
    }

    // ── Admin ───────────────────────────────────────────────────────────

    /// @notice Register a base token with its decimals. The caller-supplied
    ///         decimals are cross-checked against the token's own `decimals()`
    ///         when the token exposes one (tokens without `decimals()` are
    ///         still accepted as-is). The base must already be configured on
    ///         the master oracle so the adapter does not advertise an asset
    ///         that cannot be priced.
    ///         To change decimals: unregister then re-register.
    /// @param base The token address (non-zero, not already registered).
    /// @param decimals The token's decimals (must be <= 18).
    function registerBase(address base, uint8 decimals) external onlyAdmin {
        if (base == address(0)) revert ZeroAddress();
        // a base that equals the unit of account would have getQuote return
        // `inAmount * price / 1e18`, which is meaningful but always wrong —
        // the consumer expects `getQuote(x, unit, unit) == x`. We reject the
        // configuration entirely rather than special-case the read path.
        if (base == unitOfAccount) revert BaseIsUnitOfAccount();
        if (_baseInfo[base].registered) revert BaseAlreadyRegistered(base);
        if (decimals > MAX_DECIMALS) revert DecimalsTooLarge(decimals);

        // I-04: require the master oracle to have the base configured before
        // we advertise it as priceable. We deliberately do NOT require a
        // seeded price (which would couple adapter registration to the
        // adminSetPrice step) — configured-but-unseeded is the normal
        // intermediate state during deployment scripts. Only the
        // "completely unconfigured" case (the typo/wrong-address failure
        // mode) is caught here.
        //
        // SECURITY NOTE: `master` is `immutable` and the address is fixed at
        // adapter deployment to a `PoppieEulerOracle` instance we control;
        // `getAssetConfig` is a pure-view return of a storage struct with no
        // re-entrant surface. Static analyzers (e.g. aderyn) flag this as
        // "state change after external call" because of the `_baseInfo` write
        // a few lines below, but the call target cannot be a re-entrant
        // attacker and the only follow-on state writes are bounded by the
        // `onlyAdmin` modifier and the prior `BaseAlreadyRegistered` check.
        if (!master.getAssetConfig(base).configured) revert OracleNotReady(base);

        // I-02: cross-check the supplied decimals against the token's own
        // `decimals()` if it exposes one. Non-conforming tokens (no
        // `decimals()`) are still accepted with the admin-supplied value, so
        // we use a try/catch rather than a hard dependency on IERC20Metadata.
        // We follow checks-effects-interactions: the only "interaction" here
        // is a view call into the admin-supplied base contract, but a
        // malicious base could reenter `registerBase`. `onlyAdmin` already
        // bounds the threat, and we additionally write state BEFORE the
        // external call (`_baseInfo[base].registered = true` would cause a
        // reentrant `registerBase(base, ...)` to revert with
        // `BaseAlreadyRegistered`). On a `DecimalsMismatch` revert the whole
        // transaction unwinds and the speculative write is discarded.
        _baseInfo[base] = BaseInfo({registered: true, decimals: decimals});
        emit BaseRegistered(base, decimals);

        try IERC20Decimals(base).decimals() returns (uint8 onChain) {
            if (onChain != decimals) revert DecimalsMismatch(decimals, onChain);
        } catch {
            // token does not implement decimals(); admin value is used as-is.
        }
    }

    /// @notice Remove a base token. Subsequent quotes for it will revert.
    ///         To change decimals: unregister then re-register.
    /// @param base The token address (must be registered).
    function unregisterBase(address base) external onlyAdmin {
        if (!_baseInfo[base].registered) revert BaseNotRegistered(base);
        delete _baseInfo[base];
        emit BaseUnregistered(base);
    }

    /// @notice Start a two-step admin transfer. The new admin must call acceptAdmin.
    /// @param newAdmin Proposed new admin address (must be non-zero).
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Accept a pending admin transfer. Must be called by the pending admin.
    /// @dev    Reverts with `NoPendingAdmin` when no transfer is in flight
    ///         (`pendingAdmin == address(0)`), and `NotPendingAdmin` when a
    ///         transfer is in flight but the caller is not the pending admin.
    function acceptAdmin() external {
        address _pending = pendingAdmin;
        if (_pending == address(0)) revert NoPendingAdmin();
        if (msg.sender != _pending) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    /// @notice Returns whether a base is registered and its cached decimals.
    /// @param base The token address.
    /// @return registered True if the base is registered.
    /// @return decimals The cached decimals.
    function getBaseInfo(address base) external view returns (bool registered, uint8 decimals) {
        BaseInfo storage info = _baseInfo[base];
        return (info.registered, info.decimals);
    }

    // ── Pricing ─────────────────────────────────────────────────────────

    /// @inheritdoc IPriceOracle
    function getQuote(uint256 inAmount, address base, address quote) external view override returns (uint256 outAmount) {
        if (quote != unitOfAccount) revert UnsupportedQuote(quote);
        outAmount = _computeQuote(inAmount, base);
    }

    /// @inheritdoc IPriceOracle
    function getQuotes(uint256 inAmount, address base, address quote) external view override returns (uint256 bidOutAmount, uint256 askOutAmount) {
        if (quote != unitOfAccount) revert UnsupportedQuote(quote);
        uint256 amount = _computeQuote(inAmount, base);
        bidOutAmount = amount;
        askOutAmount = amount;
    }

    /// @dev outAmount = inAmount * price / 10^(baseDec + 18 - quoteDec)
    ///      mulDiv uses a 512-bit intermediate so inAmount * price can't overflow.
    ///      exponent is always >= 0 because baseDec <= 18 and quoteDec <= 18.
    function _computeQuote(uint256 inAmount, address base) internal view returns (uint256) {
        if (inAmount == 0) return 0;

        BaseInfo storage info = _baseInfo[base];
        if (!info.registered) revert BaseNotRegistered(base);

        // read the 18-decimal price from the oracle (reverts if stale)
        int256 price = master.getPrice(base);
        if (price <= 0) revert InvalidPrice();

        // scale: baseDec + 18 (price decimals) - quoteDec
        uint256 denominatorExp = uint256(info.decimals) + MAX_DECIMALS - uint256(unitOfAccountDecimals);

        // 512-bit multiply then divide to avoid overflow
        return Math.mulDiv(inAmount, uint256(price), 10 ** denominatorExp);
    }
}
