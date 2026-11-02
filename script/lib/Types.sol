// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Per-hub deployment parameters (CONTRACT_SPEC section 2; ARCHITECTURE "Hubs").
/// @dev Caps and cap ceilings are raw token amounts (USDC units); the scripts encode them to AmountCap, rounding
/// down. IRM values are EVK `IRMLinearKink` parameters (per-second rates in ray; kink on the uint32 utilisation
/// scale).
struct HubParams {
    string name;
    uint8 band; // IPoppieRiskSteward.RiskClass
    uint16 maxLiquidationDiscount; // 1e4 scale
    uint16 interestFee; // 1e4 scale
    uint16 originationFeeBps; // fee router, <= 100
    uint256 irmBaseRate;
    uint256 irmSlope1;
    uint256 irmSlope2;
    uint32 irmKink;
    uint256 supplyCap;
    uint256 borrowCap;
    uint256 supplyCapCeiling;
    uint256 borrowCapCeiling;
    address feeReceiver; // interest fee and origination fee; must be non-zero
}

/// @notice One Euler Earn vault: curator MS_OPS, allocator K_ALLOC, supplying the listed hubs.
struct EarnParams {
    string name;
    string symbol;
    uint256 timelock; // Earn's own timelock, set after the initial caps
    uint256 capPerHub; // raw USDC
    uint256[] hubIndexes;
}

/// @notice Everything `Deploy.s.sol` needs. Euler core is used at its canonical addresses (`evc`,
/// `eVaultFactory`); `kinkIrmFactory` and `eulerEarnFactory` are optional (zero: deploy `IRMLinearKink` directly /
/// skip Earn).
struct DeployConfig {
    address evc;
    address eVaultFactory;
    address usdc;
    address usdcUsdOracle;
    address kinkIrmFactory;
    address eulerEarnFactory;
    address msAdmin;
    address msOps;
    address reserveSafe;
    address kPrice;
    address kConfirm;
    address kTighten;
    address kGuard;
    address kAlloc;
    uint256 timelockDelay;
    HubParams[] hubs;
    EarnParams[] earns;
}

/// @notice Addresses produced by `Deploy.s.sol`.
struct Deployment {
    address deployer;
    address timelock;
    address governor; // Euler GovernorAccessControl: governorAdmin of every hub and escrow
    address router; // EulerRouter
    address oracle;
    address adapter;
    address hubHook;
    address feeRouter;
    address escrowHook;
    address wrapperFactory;
    address routerGovernor;
    address steward;
    address[] hubs;
    address[] irms;
    address[] earns;
}

/// @notice Issuer mechanism (ARCHITECTURE "Issuers"). `balance-changing` and `distributing` take the wrapper path.
enum Mechanism {
    Multiplier,
    BalanceChanging,
    Distributing
}

/// @notice One row of `config/assets.json`.
struct AssetConfig {
    string symbol;
    address token;
    Mechanism mechanism;
    uint8 riskClass; // IPoppieRiskSteward.RiskClass == IPoppieEulerOracle.PriceClass
    uint256 hubIndex; // index into Deployment.hubs: the band hub (long tail) or any hub (blue chip)
    uint256 seedAmount; // raw token units, paid by the deployer key
    uint256 supplyCapCeiling; // raw token units (of the token held by the escrow)
}

/// @notice Stage-1 output for one asset: what the deployer key created.
struct ListedAsset {
    address token;
    address wrapper; // zero for multiplier tokens
    address escrow;
}

/// @notice One Safe transaction (Transaction Builder entry).
struct SafeTx {
    address to;
    bytes data;
}
