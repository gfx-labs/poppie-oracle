// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IPriceOracle} from "./vendor/IPriceOracle.sol";
import {IPoppieEulerOracle} from "./interfaces/IPoppieEulerOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PoppieEulerAdapter
/// @author Oku / gfx labs
/// @notice Euler IPriceOracle (ERC-7726) adapter. Multi-asset singleton that
///         converts base token amounts to unitOfAccount using prices from
///         PoppieEulerOracle. Bases must be registered with explicit decimals.
///         Staleness: getQuote reverts if the underlying price is stale.
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
    error NoPendingAdmin();
    error BaseAlreadyRegistered(address base);
    error BaseNotRegistered(address base);
    error DecimalsTooLarge(uint8 decimals);
    error UnsupportedQuote(address quote);
    error InvalidPrice();
    error BaseIsUnitOfAccount();

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

    /// @notice Register a base token with its decimals. Caller supplies the
    ///         decimals explicitly — no on-chain decimals() call is made.
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
        _baseInfo[base] = BaseInfo({registered: true, decimals: decimals});
        emit BaseRegistered(base, decimals);
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
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NoPendingAdmin();
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
