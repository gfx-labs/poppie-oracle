// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IGovernance, IERC4626 as IEVKERC4626, IBorrowing} from "evk/EVault/IEVault.sol";

import {PoppieAccessControl} from "../access/PoppieAccessControl.sol";
import {MS_OPS, K_TIGHTEN, K_LOOSEN} from "../access/Roles.sol";
import {IPoppieRiskSteward} from "../interfaces/IPoppieRiskSteward.sol";

/// @title PoppieRiskSteward
/// @notice Holds the Governor roles for `setLTV` on hubs and `setCaps` on hubs and escrow vaults, and enforces the
/// value limits the Governor alone cannot (CONTRACT_SPEC.md section 3.6, V2_PLAN.md section 6).
/// @dev Every EVK write goes through the Euler `GovernorAccessControl` (`governor`), which is each vault's
/// `governorAdmin` and grants this contract the `setLTV` and `setCaps` selector roles. The target vault is appended
/// to the calldata, as `GovernorAccessControl` expects.
///
/// LTV state is read from EVK (`LTVFull`) on every call, so the steward never trusts a cached copy. It stores only
/// what EVK cannot: the liquidation-LTV baseline of the current chain of cuts, the rate-limit timestamps, the asset
/// registry, the hub list and the cap ceilings.
///
/// Ramps: EVK restarts a ramp from the current ramped value on every `setLTV`. Each write that keeps the
/// liquidation target passes the remaining ramp time, which keeps the same linear path, so an active ramp is never
/// shortened. A ramp is "active" while the current (ramped) liquidation LTV is above its target.
///
/// Blue-chip sync: an entry for a blue chip is applied to every registered hub in which the escrow is a recognised
/// collateral, whichever hub the entry names. A long-tail entry must name the asset's band hub (`WrongBand`).
///
/// Interpretations settled with the owner (Nov 2 2026), see the PR's Spec conformance section:
/// - `list` and `promote` set launch LTVs at exactly 50% of the class ceilings (the gap rule does not apply at
///   launch); `list` sets the escrow supply cap to 25% of its ceiling, rounded down, and the borrow cap to raw 1.
/// - `promote` writes only hubs other than the asset's band hub; the band hub's LTVs and the escrow caps are kept.
/// - Liquidation-LTV cut steps are measured from the current ramped value.
/// - A liquidation-LTV cut lowers the borrow LTV to `newLiquidationLtv - gap` when needed.
/// - `raiseLTV` may raise the liquidation LTV during a ramp (instant, ends the chain).
/// - Demotion ramps are exactly `cut * 24h / 5 pts` (rounded up to the second), with the 72h floor in the band hub.
/// - The gap rule is enforced whenever a borrow LTV is raised (`raiseLTV`, `overrideLTV`).
contract PoppieRiskSteward is IPoppieRiskSteward, PoppieAccessControl, ReentrancyGuardTransient {
    // -- Limits ---------------------------------------------------------------------------------

    uint16 internal constant CUT_STEP = 500; // 5 pts
    uint16 internal constant EMERGENCY_CUT_STEP = 1500; // 15 pts
    uint16 internal constant RAISE_STEP = 300; // 3 pts
    uint32 internal constant MIN_RAMP = 72 hours;
    uint32 internal constant MIN_EMERGENCY_RAMP = 12 hours;
    uint40 internal constant CUT_INTERVAL = 24 hours;
    uint40 internal constant RAISE_INTERVAL = 7 days;
    uint40 internal constant DEMOTE_WINDOW = 7 days;
    uint256 internal constant MAX_DEMOTES = 3;
    uint16 internal constant GAP_BLUE_CHIP = 500;
    uint16 internal constant GAP_LONG_TAIL = 800;
    uint16 internal constant ESCROW_BORROW_CAP = 1; // raw AmountCap "zero"

    /// @dev The Euler `GovernorAccessControl` that is `governorAdmin` of every hub and escrow vault.
    address internal immutable governor;

    // -- Storage --------------------------------------------------------------------------------

    struct Ceiling {
        uint16 supply;
        uint16 borrow;
    }

    /// @dev EVK LTV state of one (hub, collateral), plus the derived current liquidation LTV and remaining ramp.
    struct Ltv {
        uint16 borrow;
        uint16 liqTarget;
        uint16 liqNow;
        uint32 remaining; // 0 unless ramping
        bool ramping; // current liquidation LTV still above its target
        bool recognized;
    }

    mapping(address asset => AssetInfo) internal _assets;
    mapping(address escrow => address asset) internal _escrowAsset;
    address[] internal _hubList;
    mapping(address hub => bool) internal _isHub;
    mapping(address hub => RiskClass) internal _band;
    mapping(address vault => Ceiling) internal _ceilings;

    /// @dev Per (hub, asset), one slot: the liquidation-LTV baseline of the current chain of cuts and the time of
    /// the last `K_TIGHTEN` liquidation cut.
    struct HubAsset {
        uint16 baseline;
        uint40 lastLiqCut;
    }

    mapping(address hub => mapping(address asset => HubAsset)) internal _hubAsset;
    mapping(address asset => uint40) internal _lastRaise;
    uint40[MAX_DEMOTES] internal _demotes;
    uint256 internal _demoteIdx;

    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE` (see `PoppieAccessControl`).
    /// @param governor_ The Euler `GovernorAccessControl` governing every hub and escrow vault.
    constructor(address initialAdmin, address governor_) PoppieAccessControl(initialAdmin) {
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
    }

    // -- K_TIGHTEN ------------------------------------------------------------------------------

    /// @inheritdoc IPoppieRiskSteward
    function lowerBorrowLTV(BorrowLtvChange[] calldata changes) external nonReentrant onlyRole(K_TIGHTEN) {
        for (uint256 i; i < changes.length; ++i) {
            BorrowLtvChange calldata c = changes[i];
            AssetInfo memory info = _entry(c.hub, c.asset);
            address[] memory targets = _targetHubs(c.hub, info, false);
            for (uint256 j; j < targets.length; ++j) {
                address hub = targets[j];
                Ltv memory l = _ltv(hub, info.escrow);
                if (!l.recognized) continue;
                if (c.borrowLtv >= l.borrow) revert NotALowering(hub, c.asset);
                _setLTV(hub, info.escrow, c.borrowLtv, l.liqTarget, l.remaining);
                emit BorrowLtvLowered(hub, c.asset, c.borrowLtv);
            }
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function lowerLiquidationLTV(LiquidationLtvChange[] calldata changes) external nonReentrant onlyRole(K_TIGHTEN) {
        for (uint256 i; i < changes.length; ++i) {
            _lowerLiquidation(changes[i], false);
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function lowerCaps(CapChange[] calldata changes) external nonReentrant onlyRole(K_TIGHTEN) {
        for (uint256 i; i < changes.length; ++i) {
            _lowerCapsOne(changes[i]);
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function demote(address asset, RiskClass newClass, address bandHub) external nonReentrant onlyRole(K_TIGHTEN) {
        AssetInfo storage info = _assets[asset];
        if (!info.listed) revert UnknownAsset(asset);
        if (info.riskClass != RiskClass.BlueChip) revert NotBlueChip(asset);
        if (newClass == RiskClass.BlueChip) revert NotALowering(bandHub, asset);
        if (!_isHub[bandHub]) revert UnknownHub(bandHub);
        if (_band[bandHub] != newClass) revert WrongBand(bandHub, newClass);

        uint256 idx = _demoteIdx;
        uint40 oldest = _demotes[idx];
        if (oldest != 0 && block.timestamp < uint256(oldest) + DEMOTE_WINDOW) {
            revert DemoteRateLimited(oldest + DEMOTE_WINDOW);
        }
        _demotes[idx] = uint40(block.timestamp);
        _demoteIdx = (idx + 1) % MAX_DEMOTES;

        info.riskClass = newClass;
        info.bandHub = bandHub;

        uint256 n = _hubList.length;
        for (uint256 j; j < n; ++j) {
            _demoteInHub(_hubList[j], asset, info.escrow, newClass, _hubList[j] == bandHub);
        }
        emit Demoted(asset, newClass);
    }

    // -- K_LOOSEN -------------------------------------------------------------------------------

    /// @inheritdoc IPoppieRiskSteward
    function raiseLTV(LtvRaise[] calldata raises) external nonReentrant onlyRole(K_LOOSEN) {
        for (uint256 i; i < raises.length; ++i) {
            LtvRaise calldata r = raises[i];
            AssetInfo memory info = _entry(r.hub, r.asset);
            uint40 last = _lastRaise[r.asset];
            if (last != 0 && block.timestamp < uint256(last) + RAISE_INTERVAL) {
                revert RateLimited(r.hub, r.asset, last + RAISE_INTERVAL);
            }
            _lastRaise[r.asset] = uint40(block.timestamp);

            address[] memory targets = _targetHubs(r.hub, info, false);
            for (uint256 j; j < targets.length; ++j) {
                _raiseOne(targets[j], r, info);
            }
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function raiseCaps(CapChange[] calldata changes) external nonReentrant onlyRole(K_LOOSEN) {
        for (uint256 i; i < changes.length; ++i) {
            CapChange calldata c = changes[i];
            _checkCapInput(c);
            (uint256 oldS, uint256 oldB) = _resolvedCaps(c.vault);
            uint256 newS = _resolve(c.supplyCap);
            uint256 newB = _resolve(c.borrowCap);
            if (newS < oldS || newB < oldB || (newS == oldS && newB == oldB)) {
                revert NotARaise(c.vault, address(0));
            }
            _checkCeilings(c);
            _setCaps(c.vault, c.supplyCap, c.borrowCap);
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function promote(address asset) external nonReentrant onlyRole(K_LOOSEN) {
        AssetInfo storage info = _assets[asset];
        if (!info.listed) revert UnknownAsset(asset);
        if (info.riskClass == RiskClass.BlueChip) revert AlreadyPromoted(asset);

        (uint16 launchB, uint16 launchL) = _launchLtv(RiskClass.BlueChip);
        address escrow = info.escrow;
        address bandHub = info.bandHub;
        info.riskClass = RiskClass.BlueChip;
        info.bandHub = address(0);
        uint256 n = _hubList.length;
        for (uint256 j; j < n; ++j) {
            address hub = _hubList[j];
            if (hub == bandHub) continue;
            Ltv memory l = _ltv(hub, escrow);
            uint32 ramp = 0;
            // Still ramping down from an earlier demotion above the launch value: keep ramping, never cut instantly.
            if (l.liqNow > launchL) ramp = l.remaining > MIN_RAMP ? l.remaining : MIN_RAMP;
            _setLTV(hub, escrow, launchB, launchL, ramp);
        }
        emit Promoted(asset);
    }

    // -- DEFAULT_ADMIN_ROLE ---------------------------------------------------------------------

    /// @inheritdoc IPoppieRiskSteward
    /// @dev A hub can be registered once; registering it again reverts `WrongBand(hub, currentBand)`.
    function addHub(address hub, RiskClass band) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hub == address(0)) revert ZeroAddress();
        if (_isHub[hub]) revert WrongBand(hub, _band[hub]);
        _isHub[hub] = true;
        _band[hub] = band;
        _hubList.push(hub);
        emit HubAdded(hub, band);
    }

    // -- MS_OPS ---------------------------------------------------------------------------------

    /// @inheritdoc IPoppieRiskSteward
    function list(Listing[] calldata listings) external nonReentrant onlyRole(MS_OPS) {
        for (uint256 i; i < listings.length; ++i) {
            _listOne(listings[i]);
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function setCapCeiling(CapCeilingChange[] calldata changes) external nonReentrant onlyRole(MS_OPS) {
        for (uint256 i; i < changes.length; ++i) {
            CapCeilingChange calldata c = changes[i];
            if (c.vault == address(0)) revert ZeroAddress();
            if (c.supplyCapCeiling == 0 || c.borrowCapCeiling == 0) revert ZeroCapNotAllowed();
            _ceilings[c.vault] = Ceiling(c.supplyCapCeiling, c.borrowCapCeiling);
            emit CapCeilingSet(c.vault, c.supplyCapCeiling, c.borrowCapCeiling);
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function overrideLTV(BorrowLtvChange[] calldata changes) external nonReentrant onlyRole(MS_OPS) {
        for (uint256 i; i < changes.length; ++i) {
            BorrowLtvChange calldata c = changes[i];
            AssetInfo memory info = _entry(c.hub, c.asset);
            (uint16 ceilB,) = classCeilings(info.riskClass);
            uint16 gap = _gap(info.riskClass);
            address[] memory targets = _targetHubs(c.hub, info, false);
            for (uint256 j; j < targets.length; ++j) {
                address hub = targets[j];
                Ltv memory l = _ltv(hub, info.escrow);
                if (!l.recognized) continue;
                if (c.borrowLtv > ceilB) revert ExceedsClassCeiling(hub, c.asset, c.borrowLtv, ceilB);
                if (c.borrowLtv > l.liqTarget) revert BorrowLtvAboveLiquidationLtv(hub, c.asset);
                if (c.borrowLtv > l.borrow && uint256(c.borrowLtv) + gap > l.liqTarget) {
                    revert GapRuleViolated(hub, c.asset);
                }
                _setLTV(hub, info.escrow, c.borrowLtv, l.liqTarget, l.remaining);
                emit BorrowLtvOverridden(hub, c.asset, c.borrowLtv);
            }
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function overrideCaps(CapChange[] calldata changes) external nonReentrant onlyRole(MS_OPS) {
        for (uint256 i; i < changes.length; ++i) {
            CapChange calldata c = changes[i];
            _checkCapInput(c);
            _checkCeilings(c);
            _setCaps(c.vault, c.supplyCap, c.borrowCap);
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function cancelRamp(RampRef[] calldata refs) external nonReentrant onlyRole(MS_OPS) {
        for (uint256 i; i < refs.length; ++i) {
            RampRef calldata r = refs[i];
            AssetInfo memory info = _entry(r.hub, r.asset);
            address[] memory targets = _targetHubs(r.hub, info, true);
            for (uint256 j; j < targets.length; ++j) {
                _cancelRampInHub(targets[j], r.asset, info);
            }
        }
    }

    /// @inheritdoc IPoppieRiskSteward
    function emergencyLowerLiquidationLTV(LiquidationLtvChange[] calldata changes)
        external
        nonReentrant
        onlyRole(MS_OPS)
    {
        for (uint256 i; i < changes.length; ++i) {
            _lowerLiquidation(changes[i], true);
        }
    }

    // -- Views ----------------------------------------------------------------------------------

    /// @inheritdoc IPoppieRiskSteward
    function assetInfo(address asset) external view returns (AssetInfo memory) {
        return _assets[asset];
    }

    /// @inheritdoc IPoppieRiskSteward
    function hubs() external view returns (address[] memory) {
        return _hubList;
    }

    /// @inheritdoc IPoppieRiskSteward
    function hubBand(address hub) external view returns (RiskClass) {
        if (!_isHub[hub]) revert UnknownHub(hub);
        return _band[hub];
    }

    /// @inheritdoc IPoppieRiskSteward
    function liquidationLtvBaseline(address hub, address asset) external view returns (uint16) {
        AssetInfo storage info = _assets[asset];
        if (!info.listed || !_isHub[hub]) return 0;
        if (!_ltv(hub, info.escrow).ramping) return 0;
        return _hubAsset[hub][asset].baseline;
    }

    /// @inheritdoc IPoppieRiskSteward
    function capCeilings(address vault) external view returns (uint16 supplyCapCeiling, uint16 borrowCapCeiling) {
        Ceiling memory c = _ceilings[vault];
        return (c.supply, c.borrow);
    }

    /// @inheritdoc IPoppieRiskSteward
    function classCeilings(RiskClass riskClass) public pure returns (uint16 borrowLtv, uint16 liquidationLtv) {
        if (riskClass == RiskClass.BlueChip) return (7000, 7500);
        if (riskClass == RiskClass.M1) return (5000, 5800);
        if (riskClass == RiskClass.M2) return (4500, 5200);
        return (3500, 4200);
    }

    // -- Internal: LTV --------------------------------------------------------------------------

    /// @dev `emergency`: the MS_OPS path (<= 15 pts, ramp >= 12h, no rate limit); otherwise the K_TIGHTEN limits
    /// (<= 5 pts, ramp >= 72h, once per asset per hub per 24h).
    function _lowerLiquidation(LiquidationLtvChange calldata c, bool emergency) internal {
        AssetInfo memory info = _entry(c.hub, c.asset);
        address[] memory targets = _targetHubs(c.hub, info, false);
        for (uint256 j; j < targets.length; ++j) {
            _lowerLiquidationInHub(targets[j], c, info, emergency);
        }
    }

    function _lowerLiquidationInHub(address hub, LiquidationLtvChange calldata c, AssetInfo memory info, bool emergency)
        internal
    {
        Ltv memory l = _ltv(hub, info.escrow);
        if (!l.recognized) return;
        if (c.liquidationLtv >= l.liqTarget) revert NotALowering(hub, c.asset);
        _checkCut(hub, c, l, emergency);
        HubAsset memory ha = _hubAsset[hub][c.asset];
        if (!emergency) {
            if (ha.lastLiqCut != 0 && block.timestamp < uint256(ha.lastLiqCut) + CUT_INTERVAL) {
                revert RateLimited(hub, c.asset, ha.lastLiqCut + CUT_INTERVAL);
            }
            ha.lastLiqCut = uint40(block.timestamp);
        }
        if (!l.ramping) ha.baseline = l.liqNow;
        _hubAsset[hub][c.asset] = ha;
        uint16 gap = _gap(info.riskClass);
        uint16 maxBorrow = c.liquidationLtv > gap ? c.liquidationLtv - gap : 0;
        _setLTV(hub, info.escrow, _min(l.borrow, maxBorrow), c.liquidationLtv, c.rampDuration);
        emit LiquidationLtvLowered(hub, c.asset, c.liquidationLtv, c.rampDuration, ha.baseline);
    }

    function _checkCut(address hub, LiquidationLtvChange calldata c, Ltv memory l, bool emergency) internal pure {
        uint16 maxStep = emergency ? EMERGENCY_CUT_STEP : CUT_STEP;
        uint16 step = l.liqNow - c.liquidationLtv;
        if (step > maxStep) revert StepTooLarge(hub, c.asset, step, maxStep);
        uint32 minRamp = emergency ? MIN_EMERGENCY_RAMP : MIN_RAMP;
        if (l.remaining > minRamp) minRamp = l.remaining;
        if (c.rampDuration < minRamp) revert RampTooShort(hub, c.asset, c.rampDuration, minRamp);
    }

    /// @dev Demotion in one hub. Leaving: borrow 0 at once, liquidation ramps to 0 over >= cut x 24h / 5 pts. Band
    /// hub: borrow to the new class ceiling at once, liquidation ramps to it over the same, never under 72h. Never
    /// shorter than an active ramp.
    function _demoteInHub(address hub, address asset, address escrow, RiskClass newClass, bool stays) internal {
        Ltv memory l = _ltv(hub, escrow);
        if (!l.recognized) return;
        (uint16 ceilB, uint16 ceilL) = classCeilings(newClass);
        uint16 newB = stays ? _min(l.borrow, ceilB) : 0;
        uint16 newL = stays ? _min(l.liqTarget, ceilL) : 0;
        uint32 ramp = l.remaining;
        if (l.liqNow > newL) {
            uint256 r = Math.ceilDiv(uint256(l.liqNow - newL) * 1 days, CUT_STEP);
            if (stays && r < MIN_RAMP) r = MIN_RAMP;
            if (r < l.remaining) r = l.remaining;
            ramp = uint32(r);
            if (!l.ramping) _hubAsset[hub][asset].baseline = l.liqNow;
        }
        _setLTV(hub, escrow, newB, newL, ramp);
    }

    /// @dev Restoring is a raise and takes effect at once. If the class ceiling is below the current ramped value (a
    /// demoted asset), the ramp keeps its time but stops at the ceiling: never an instant cut.
    function _cancelRampInHub(address hub, address asset, AssetInfo memory info) internal {
        Ltv memory l = _ltv(hub, info.escrow);
        if (!l.recognized) return;
        uint16 baseline = _hubAsset[hub][asset].baseline;
        if (!l.ramping || baseline <= l.liqTarget) revert NoActiveRamp(hub, asset);
        (, uint16 ceilL) = classCeilings(info.riskClass);
        uint16 restored = _min(baseline, ceilL);
        uint32 ramp = restored >= l.liqNow ? 0 : l.remaining;
        if (restored < l.liqTarget) restored = l.liqTarget;
        _hubAsset[hub][asset].baseline = 0;
        _setLTV(hub, info.escrow, l.borrow, restored, ramp);
        emit RampCancelled(hub, asset, restored);
    }

    function _raiseOne(address hub, LtvRaise calldata r, AssetInfo memory info) internal {
        Ltv memory l = _ltv(hub, info.escrow);
        if (!l.recognized) return;
        (uint16 ceilB, uint16 ceilL) = classCeilings(info.riskClass);

        if (r.borrowLtv < l.borrow) revert NotARaise(hub, r.asset);
        bool borrowUp = r.borrowLtv > l.borrow;
        if (r.borrowLtv - l.borrow > RAISE_STEP) {
            revert StepTooLarge(hub, r.asset, r.borrowLtv - l.borrow, RAISE_STEP);
        }

        uint32 ramp = l.remaining;
        bool liqUp = r.liquidationLtv != l.liqTarget;
        if (liqUp) {
            // A liquidation raise is instant and ends any active ramp (and its chain).
            if (r.liquidationLtv <= l.liqNow) revert NotARaise(hub, r.asset);
            if (r.liquidationLtv - l.liqNow > RAISE_STEP) {
                revert StepTooLarge(hub, r.asset, r.liquidationLtv - l.liqNow, RAISE_STEP);
            }
            ramp = 0;
        }
        if (!borrowUp && !liqUp) revert NotARaise(hub, r.asset);

        if (r.borrowLtv > ceilB) revert ExceedsClassCeiling(hub, r.asset, r.borrowLtv, ceilB);
        if (r.liquidationLtv > ceilL) revert ExceedsClassCeiling(hub, r.asset, r.liquidationLtv, ceilL);
        if (r.borrowLtv > r.liquidationLtv) revert BorrowLtvAboveLiquidationLtv(hub, r.asset);
        if (borrowUp && uint256(r.borrowLtv) + _gap(info.riskClass) > r.liquidationLtv) {
            revert GapRuleViolated(hub, r.asset);
        }

        if (liqUp) _hubAsset[hub][r.asset].baseline = 0;
        _setLTV(hub, info.escrow, r.borrowLtv, r.liquidationLtv, ramp);
        emit LtvRaised(hub, r.asset, r.borrowLtv, r.liquidationLtv);
    }

    function _listOne(Listing calldata li) internal {
        if (li.asset == address(0) || li.escrow == address(0)) revert ZeroAddress();
        if (_assets[li.asset].listed || _escrowAsset[li.escrow] != address(0)) revert AlreadyListed(li.asset);
        if (!_isHub[li.hub]) revert UnknownHub(li.hub);
        if (li.riskClass != RiskClass.BlueChip && _band[li.hub] != li.riskClass) {
            revert WrongBand(li.hub, li.riskClass);
        }
        Ceiling memory ceiling = _ceilings[li.escrow];
        if (ceiling.supply == 0) revert CapCeilingNotSet(li.escrow);

        // The escrow holds the token directly, or a wrapper of it.
        address held = IERC4626(li.escrow).asset();
        address wrapper = address(0);
        if (held != li.asset) {
            if (IERC4626(held).asset() != li.asset) revert UnknownVault(li.escrow);
            wrapper = held;
        }

        _assets[li.asset] = AssetInfo({
            wrapper: wrapper,
            escrow: li.escrow,
            riskClass: li.riskClass,
            bandHub: li.riskClass == RiskClass.BlueChip ? address(0) : li.hub,
            listed: true
        });
        _escrowAsset[li.escrow] = li.asset;
        _setLaunchLtv(li);

        _setCaps(li.escrow, _encodeCapDown(_resolve(ceiling.supply) / 4), ESCROW_BORROW_CAP);
        emit Listed(li.asset, li.escrow, li.hub, li.riskClass);
    }

    function _setLaunchLtv(Listing calldata li) internal {
        (uint16 launchB, uint16 launchL) = _launchLtv(li.riskClass);
        if (li.riskClass != RiskClass.BlueChip) return _setLTV(li.hub, li.escrow, launchB, launchL, 0);
        uint256 n = _hubList.length;
        for (uint256 j; j < n; ++j) {
            _setLTV(_hubList[j], li.escrow, launchB, launchL, 0);
        }
    }

    /// @dev Validates an entry's hub and asset; returns the asset's record.
    function _entry(address hub, address asset) internal view returns (AssetInfo memory info) {
        if (!_isHub[hub]) revert UnknownHub(hub);
        info = _assets[asset];
        if (!info.listed) revert UnknownAsset(asset);
    }

    /// @dev Hubs an entry applies to: every hub for a blue chip; otherwise only the band hub, unless `anyHub`
    /// (ramp cancel, which also reaches the hubs a demoted asset is leaving).
    function _targetHubs(address hub, AssetInfo memory info, bool anyHub) internal view returns (address[] memory t) {
        if (info.riskClass == RiskClass.BlueChip) return _hubList;
        if (!anyHub && hub != info.bandHub) revert WrongBand(hub, info.riskClass);
        t = new address[](1);
        t[0] = hub;
    }

    function _ltv(address hub, address escrow) internal view returns (Ltv memory l) {
        (uint16 borrow, uint16 liqTarget, uint16 initial, uint48 targetTs, uint32 rampDuration) =
            IGovernance(hub).LTVFull(escrow);
        l.borrow = borrow;
        l.liqTarget = liqTarget;
        l.liqNow = liqTarget;
        l.recognized = targetTs != 0;
        if (block.timestamp < targetTs && liqTarget < initial) {
            l.liqNow = _ramped(liqTarget, initial, targetTs - block.timestamp, rampDuration);
            if (l.liqNow > liqTarget) {
                l.ramping = true;
                l.remaining = uint32(targetTs - block.timestamp);
            }
        }
    }

    /// @dev Same formula as EVK's `LTVConfigLib.getLTV`.
    function _ramped(uint16 target, uint16 initial, uint256 timeRemaining, uint32 rampDuration)
        internal
        pure
        returns (uint16)
    {
        return uint16(target + uint256(initial - target) * timeRemaining / rampDuration);
    }

    function _launchLtv(RiskClass riskClass) internal pure returns (uint16, uint16) {
        (uint16 b, uint16 l) = classCeilings(riskClass);
        return (b / 2, l / 2);
    }

    function _gap(RiskClass riskClass) internal pure returns (uint16) {
        return riskClass == RiskClass.BlueChip ? GAP_BLUE_CHIP : GAP_LONG_TAIL;
    }

    function _min(uint16 a, uint16 b) internal pure returns (uint16) {
        return a < b ? a : b;
    }

    // -- Internal: caps -------------------------------------------------------------------------

    function _lowerCapsOne(CapChange calldata c) internal {
        bool isEscrow = _checkCapInput(c);
        (uint256 oldS, uint256 oldB) = _resolvedCaps(c.vault);
        uint256 newS = _resolve(c.supplyCap);
        uint256 newB = _resolve(c.borrowCap);
        if (newS > oldS || newB > oldB || (newS == oldS && newB == oldB)) revert NotALowering(c.vault, address(0));
        if (newS < oldS && newS < IEVKERC4626(c.vault).totalAssets()) revert BelowCurrentUsage(c.vault, c.supplyCap);
        if (!isEscrow && newB < oldB && newB < IBorrowing(c.vault).totalBorrows()) {
            revert BelowCurrentUsage(c.vault, c.borrowCap);
        }
        _setCaps(c.vault, c.supplyCap, c.borrowCap);
    }

    function _resolvedCaps(address vault) internal view returns (uint256 supply, uint256 borrow) {
        (uint16 s, uint16 b) = IGovernance(vault).caps();
        return (_resolve(s), _resolve(b));
    }

    /// @dev Common cap-entry checks. Returns true for an escrow vault, false for a hub.
    function _checkCapInput(CapChange calldata c) internal view returns (bool isEscrow) {
        isEscrow = _escrowAsset[c.vault] != address(0);
        if (!isEscrow && !_isHub[c.vault]) revert UnknownVault(c.vault);
        if (c.supplyCap == 0 || c.borrowCap == 0) revert ZeroCapNotAllowed();
        if (isEscrow && c.borrowCap != ESCROW_BORROW_CAP) revert EscrowBorrowCapMustStayZero(c.vault);
    }

    function _checkCeilings(CapChange calldata c) internal view {
        Ceiling memory ceiling = _ceilings[c.vault];
        if (ceiling.supply == 0) revert CapCeilingNotSet(c.vault);
        if (_resolve(c.supplyCap) > _resolve(ceiling.supply)) {
            revert ExceedsCapCeiling(c.vault, c.supplyCap, ceiling.supply);
        }
        // Escrow borrow caps are pinned to raw 1 by `_checkCapInput`; their borrow ceiling is unused.
        if (_isHub[c.vault] && _resolve(c.borrowCap) > _resolve(ceiling.borrow)) {
            revert ExceedsCapCeiling(c.vault, c.borrowCap, ceiling.borrow);
        }
    }

    /// @dev Resolve a raw AmountCap like EVK's `AmountCapLib.resolve` (raw 0 = unlimited).
    function _resolve(uint16 raw) internal pure returns (uint256) {
        if (raw == 0) return type(uint256).max;
        return 10 ** (raw & 63) * (raw >> 6) / 100;
    }

    /// @dev Encode `amount` as the largest AmountCap whose resolved value is `<= amount`. Never raw 0: an amount of
    /// zero encodes as raw 1.
    function _encodeCapDown(uint256 amount) internal pure returns (uint16) {
        if (amount == 0) return ESCROW_BORROW_CAP;
        uint256 mantissa = amount * 100;
        uint256 exponent;
        while (mantissa > 1023) {
            mantissa /= 10;
            ++exponent;
        }
        return uint16((mantissa << 6) | exponent);
    }

    // -- Internal: governor calls ---------------------------------------------------------------

    function _setLTV(address hub, address escrow, uint16 borrowLtv, uint16 liquidationLtv, uint32 ramp) internal {
        _govCall(hub, abi.encodeCall(IGovernance.setLTV, (escrow, borrowLtv, liquidationLtv, ramp)));
    }

    function _setCaps(address vault, uint16 supplyCap, uint16 borrowCap) internal {
        _govCall(vault, abi.encodeCall(IGovernance.setCaps, (supplyCap, borrowCap)));
        emit CapsSet(vault, supplyCap, borrowCap, msg.sender);
    }

    /// @dev `GovernorAccessControl` reads the target from the last 20 bytes of calldata.
    function _govCall(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = governor.call(abi.encodePacked(data, target));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
