// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoppieRiskSteward
/// @notice Holds the Governor roles for `setLTV` on hubs and `setCaps` on hubs and escrow vaults, and
/// enforces the value limits the Governor alone cannot (CONTRACT_SPEC.md section 3.6).
/// @dev Units:
///      - LTVs are EVK `uint16` values on a 1e4 scale (7000 = 70%). "pts" are 100 per percentage point.
///      - Caps are EVK's 16-bit AmountCap encoding, passed raw: raw 0 means unlimited, "zero" is raw 1.
///        The steward compares resolved amounts, rounds down after encoding and never writes raw 0.
///        Cap ceilings use the same encoding and must not be raw 0.
///      - Durations are seconds.
///      Every mutating function takes arrays so a batch (up to 500 entries) is one call. A blue-chip change
///      is applied to every hub in the same call, whichever hub the entry names.
///      Roles: `K_TIGHTEN`, `K_LOOSEN`, `MS_OPS`.
interface IPoppieRiskSteward {
    /// @notice Risk class. Ceilings (borrow / liquidation LTV): BlueChip 70/75, M1 50/58, M2 45/52, M3 35/42.
    /// Minimum gap between the two: 5 pts for BlueChip, 8 pts for long tail.
    enum RiskClass {
        BlueChip,
        M1,
        M2,
        M3
    }

    /// @notice Stored per listed asset (the underlying token).
    struct AssetInfo {
        address wrapper; // zero when the token needs no wrapper
        address escrow; // escrow vault holding the token or its wrapper
        RiskClass riskClass;
        address bandHub; // the long-tail band hub; zero for BlueChip
        uint16 supplyCapCeiling; // raw AmountCap, never 0
        uint16 borrowCapCeiling; // raw AmountCap; the escrow borrow cap stays raw 1
        bool listed;
    }

    struct BorrowLtvChange {
        address hub;
        address asset;
        uint16 borrowLtv;
    }

    struct LiquidationLtvChange {
        address hub;
        address asset;
        uint16 liquidationLtv;
        uint32 rampDuration;
    }

    struct LtvRaise {
        address hub;
        address asset;
        uint16 borrowLtv;
        uint16 liquidationLtv;
    }

    struct CapChange {
        address vault;
        uint16 supplyCap;
        uint16 borrowCap;
    }

    struct CapCeilingChange {
        address vault;
        uint16 supplyCapCeiling;
        uint16 borrowCapCeiling;
    }

    struct Listing {
        address asset;
        address escrow;
        address hub;
        RiskClass riskClass;
    }

    struct RampRef {
        address hub;
        address asset;
    }

    // -- Events ---------------------------------------------------------------------------------

    event HubAdded(address indexed hub, RiskClass indexed band);
    event Listed(address indexed asset, address indexed escrow, address indexed hub, RiskClass riskClass);
    event BorrowLtvLowered(address indexed hub, address indexed asset, uint16 borrowLtv);
    /// @param baseline The liquidation LTV recorded before the first cut of the chain (see ramp cancel).
    event LiquidationLtvLowered(
        address indexed hub, address indexed asset, uint16 liquidationLtv, uint32 rampDuration, uint16 baseline
    );
    event LtvRaised(address indexed hub, address indexed asset, uint16 borrowLtv, uint16 liquidationLtv);
    event CapsSet(address indexed vault, uint16 supplyCap, uint16 borrowCap, address indexed by);
    event CapCeilingSet(address indexed vault, uint16 supplyCapCeiling, uint16 borrowCapCeiling);
    event Promoted(address indexed asset);
    event Demoted(address indexed asset, RiskClass newClass);
    event BorrowLtvOverridden(address indexed hub, address indexed asset, uint16 borrowLtv);
    event RampCancelled(address indexed hub, address indexed asset, uint16 restoredLiquidationLtv);

    // -- Errors ---------------------------------------------------------------------------------

    error ZeroAddress();
    error LengthMismatch();
    error UnknownHub(address hub);
    error UnknownAsset(address asset);
    error AlreadyListed(address asset);
    error AlreadyPromoted(address asset);
    error NotBlueChip(address asset);
    /// @dev A lowering function was given a value that is not lower, or a raise one that is not higher.
    error NotALowering(address hub, address asset);
    error NotARaise(address hub, address asset);
    error ExceedsClassCeiling(address hub, address asset, uint16 value, uint16 ceiling);
    error BorrowLtvAboveLiquidationLtv(address hub, address asset);
    error GapRuleViolated(address hub, address asset);
    /// @dev Liquidation-LTV cut above 5 pts (15 pts for the emergency path), or raise above 3 pts.
    error StepTooLarge(address hub, address asset, uint16 step, uint16 maxStep);
    /// @dev Ramp shorter than 72h (12h for the emergency path), or shorter than the remaining ramp.
    error RampTooShort(address hub, address asset, uint32 rampDuration, uint32 minDuration);
    /// @dev Per-asset rate limit; `nextAllowedAt` is when the next call is allowed.
    error RateLimited(address hub, address asset, uint40 nextAllowedAt);
    error DemoteRateLimited(uint40 nextAllowedAt);
    error ExceedsCapCeiling(address vault, uint16 cap, uint16 ceiling);
    /// @dev Raw 0 (unlimited) is never written, and never accepted as a ceiling.
    error ZeroCapNotAllowed();
    /// @dev `K_TIGHTEN` cap cut below current usage; needs `overrideCaps`.
    error BelowCurrentUsage(address vault, uint16 cap);
    /// @dev Escrow borrow caps stay at raw 1.
    error EscrowBorrowCapMustStayZero(address vault);
    /// @dev Launch limits on `list`: LTV <= 50% of class ceiling, supply cap <= 25% of cap ceiling.
    error ExceedsLaunchLimit(address asset);
    error NoActiveRamp(address hub, address asset);
    error PromoteMustCoverAllHubs();

    // -- K_TIGHTEN ------------------------------------------------------------------------------

    /// @notice Lower borrow LTVs. Any amount, instant, no limit on batch size.
    function lowerBorrowLTV(BorrowLtvChange[] calldata changes) external;

    /// @notice Lower liquidation LTVs. <= 5 pts per call; ramp >= 72h and >= the remaining ramp; once per
    /// asset per hub per 24h. No limit on how many assets are cut per day.
    function lowerLiquidationLTV(LiquidationLtvChange[] calldata changes) external;

    /// @notice Lower caps, down to current usage; below that needs `overrideCaps`.
    function lowerCaps(CapChange[] calldata changes) external;

    /// @notice Demote an asset to long tail. In hubs it is leaving: borrow LTV to 0 at once, liquidation LTV
    /// ramps to 0 over >= (cut / 5 pts) x 24h. In the band hub it stays in: borrow LTV drops to the new class
    /// ceiling at once and liquidation LTV ramps down over >= (cut / 5 pts) x 24h, never under 72h.
    /// Rate limit: <= 3 per rolling 7 days.
    function demote(address asset, RiskClass newClass, address bandHub) external;

    // -- K_LOOSEN -------------------------------------------------------------------------------

    /// @notice Raise LTVs. <= 3 pts per change; once per asset per 7 days; <= class ceiling; gap rule.
    function raiseLTV(LtvRaise[] calldata raises) external;

    /// @notice Raise caps up to each asset's cap ceiling, with no rate limit.
    function raiseCaps(CapChange[] calldata changes) external;

    /// @notice List a newly promoted blue chip in every hub, in one call, at launch limits. All-or-nothing:
    /// `allHubs` must be every hub, else `PromoteMustCoverAllHubs`.
    function promote(address asset, address[] calldata allHubs) external;

    // -- DEFAULT_ADMIN_ROLE (timelock) ----------------------------------------------------------

    /// @notice Register a hub and its band (`BlueChip` for the Prime hub). Role `DEFAULT_ADMIN_ROLE`, like
    /// the hub hook's `registerHub`.
    function addHub(address hub, RiskClass band) external;

    // -- MS_OPS ---------------------------------------------------------------------------------

    /// @notice New listing: LTV <= 50% of the class ceiling, supply cap <= 25% of the cap ceiling.
    /// The cap ceilings must be set first (`setCapCeiling`).
    function list(Listing[] calldata listings) external;

    /// @notice Set or raise cap ceilings, instantly. Binds `K_LOOSEN`, which cannot change them.
    function setCapCeiling(CapCeilingChange[] calldata changes) external;

    /// @notice Set the borrow LTV anywhere up to the class ceiling, without the weekly limit. The borrow LTV
    /// cannot exceed the liquidation LTV and the gap rule applies. Does not raise the liquidation LTV.
    function overrideLTV(BorrowLtvChange[] calldata changes) external;

    /// @notice Set caps anywhere up to the cap ceilings, without a rate limit.
    function overrideCaps(CapChange[] calldata changes) external;

    /// @notice For a liquidation-LTV cut or demotion still ramping: restore the liquidation LTV recorded
    /// before the first cut of the chain, never above the class ceiling.
    function cancelRamp(RampRef[] calldata refs) external;

    /// @notice <= 15 pts; ramp >= 12h.
    function emergencyLowerLiquidationLTV(LiquidationLtvChange[] calldata changes) external;

    // -- Views ----------------------------------------------------------------------------------

    function assetInfo(address asset) external view returns (AssetInfo memory);
    function hubs() external view returns (address[] memory);
    function hubBand(address hub) external view returns (RiskClass);
    /// @notice Liquidation LTV in force before the current chain of cuts; 0 when no chain is active.
    function liquidationLtvBaseline(address hub, address asset) external view returns (uint16);
    /// @notice (borrow, liquidation) LTV ceilings for a class.
    function classCeilings(RiskClass riskClass) external view returns (uint16 borrowLtv, uint16 liquidationLtv);
}
