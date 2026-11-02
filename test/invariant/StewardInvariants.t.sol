// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {StewardFixture, StewardHarness} from "../harness/StewardFixture.sol";

/// @notice Random driver for every steward role function (K_TIGHTEN, K_LOOSEN, MS_OPS) plus time warps. Reverting
/// calls are expected and swallowed. Tightening calls are checked inline: they never raise a current liquidation
/// LTV in any hub and never bring an active ramp's end forward.
contract StewardHandler is Test {
    StewardHarness internal immutable steward;
    address internal immutable ops;
    address internal immutable tightener;
    address internal immutable loosener;

    address[] public assets;
    IEVault[] public escrows;
    IEVault[] internal hubList;

    uint256 public tightenViolations;
    uint256 public calls;

    constructor(
        StewardHarness steward_,
        address ops_,
        address tightener_,
        address loosener_,
        address[] memory assets_,
        IEVault[] memory escrows_,
        IEVault[] memory hubs_
    ) {
        steward = steward_;
        ops = ops_;
        tightener = tightener_;
        loosener = loosener_;
        assets = assets_;
        escrows = escrows_;
        hubList = hubs_;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function _pick(uint256 seed) internal view returns (address asset, IEVault escrow, IEVault hub) {
        uint256 i = seed % assets.length;
        asset = assets[i];
        escrow = escrows[i];
        IPoppieRiskSteward.AssetInfo memory info = steward.assetInfo(asset);
        hub = info.bandHub == address(0) ? hubList[(seed >> 8) % hubList.length] : IEVault(info.bandHub);
    }

    struct Snap {
        uint16[4] liqNow;
        uint48[4] end;
        bool[4] ramping;
    }

    function _snap(IEVault escrow) internal view returns (Snap memory s) {
        for (uint256 h; h < hubList.length; ++h) {
            (, uint16 target,, uint48 end,) = hubList[h].LTVFull(address(escrow));
            s.liqNow[h] = hubList[h].LTVLiquidation(address(escrow));
            s.end[h] = end;
            s.ramping[h] = s.liqNow[h] > target && block.timestamp < end;
        }
    }

    function _checkTighten(IEVault escrow, Snap memory before) internal {
        Snap memory afterS = _snap(escrow);
        for (uint256 h; h < hubList.length; ++h) {
            if (afterS.liqNow[h] > before.liqNow[h]) ++tightenViolations;
            if (before.ramping[h] && afterS.end[h] < before.end[h]) ++tightenViolations;
        }
    }

    // -- K_TIGHTEN ------------------------------------------------------------------------------

    function lowerBorrow(uint256 seed, uint16 ltv) external {
        (address asset, IEVault escrow, IEVault hub) = _pick(seed);
        Snap memory s = _snap(escrow);
        IPoppieRiskSteward.BorrowLtvChange[] memory c = new IPoppieRiskSteward.BorrowLtvChange[](1);
        c[0] = IPoppieRiskSteward.BorrowLtvChange(address(hub), asset, uint16(bound(ltv, 0, 7500)));
        vm.prank(tightener);
        try steward.lowerBorrowLTV(c) {
            ++calls;
            _checkTighten(escrow, s);
        } catch {}
    }

    function lowerLiquidation(uint256 seed, uint16 step, uint32 ramp) external {
        (address asset, IEVault escrow, IEVault hub) = _pick(seed);
        Snap memory s = _snap(escrow);
        uint16 cur = hub.LTVLiquidation(address(escrow));
        uint16 newL = cur > 600 ? cur - uint16(bound(step, 1, 600)) : 0;
        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](1);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(
            address(hub), asset, newL, uint32(bound(ramp, 71 hours, 400 hours))
        );
        vm.prank(tightener);
        try steward.lowerLiquidationLTV(c) {
            ++calls;
            _checkTighten(escrow, s);
        } catch {}
    }

    function demote(uint256 seed, uint8 cls) external {
        (address asset, IEVault escrow,) = _pick(seed);
        IPoppieRiskSteward.RiskClass newClass = IPoppieRiskSteward.RiskClass(bound(cls, 1, 3));
        Snap memory s = _snap(escrow);
        vm.prank(tightener);
        try steward.demote(asset, newClass, address(hubList[uint8(newClass)])) {
            ++calls;
            _checkTighten(escrow, s);
        } catch {}
    }

    // -- K_LOOSEN -------------------------------------------------------------------------------

    function raise(uint256 seed, uint16 db, uint16 dl) external {
        (address asset, IEVault escrow, IEVault hub) = _pick(seed);
        uint16 b = hub.LTVBorrow(address(escrow));
        uint16 l = hub.LTVLiquidation(address(escrow));
        IPoppieRiskSteward.LtvRaise[] memory c = new IPoppieRiskSteward.LtvRaise[](1);
        c[0] = IPoppieRiskSteward.LtvRaise(
            address(hub), asset, b + uint16(bound(db, 0, 350)), l + uint16(bound(dl, 0, 350))
        );
        vm.prank(loosener);
        try steward.raiseLTV(c) {
            ++calls;
        } catch {}
    }

    function promote(uint256 seed) external {
        (address asset,,) = _pick(seed);
        vm.prank(loosener);
        try steward.promote(asset) {
            ++calls;
        } catch {}
    }

    function raiseCaps(uint256 seed, uint16 raw) external {
        (, IEVault escrow,) = _pick(seed);
        IPoppieRiskSteward.CapChange[] memory c = new IPoppieRiskSteward.CapChange[](1);
        c[0] = IPoppieRiskSteward.CapChange(address(escrow), uint16(bound(raw, 1, type(uint16).max)), 1);
        vm.prank(loosener);
        try steward.raiseCaps(c) {
            ++calls;
        } catch {}
    }

    // -- MS_OPS ---------------------------------------------------------------------------------

    function overrideBorrow(uint256 seed, uint16 ltv) external {
        (address asset,, IEVault hub) = _pick(seed);
        IPoppieRiskSteward.BorrowLtvChange[] memory c = new IPoppieRiskSteward.BorrowLtvChange[](1);
        c[0] = IPoppieRiskSteward.BorrowLtvChange(address(hub), asset, uint16(bound(ltv, 0, 7500)));
        vm.prank(ops);
        try steward.overrideLTV(c) {
            ++calls;
        } catch {}
    }

    function cancelRamp(uint256 seed) external {
        (address asset,, IEVault hub) = _pick(seed);
        IPoppieRiskSteward.RampRef[] memory r = new IPoppieRiskSteward.RampRef[](1);
        r[0] = IPoppieRiskSteward.RampRef(address(hub), asset);
        vm.prank(ops);
        try steward.cancelRamp(r) {
            ++calls;
        } catch {}
    }

    function emergency(uint256 seed, uint16 step, uint32 ramp) external {
        (address asset, IEVault escrow, IEVault hub) = _pick(seed);
        uint16 cur = hub.LTVLiquidation(address(escrow));
        uint16 newL = cur > 1600 ? cur - uint16(bound(step, 1, 1600)) : 0;
        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](1);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(
            address(hub), asset, newL, uint32(bound(ramp, 11 hours, 100 hours))
        );
        vm.prank(ops);
        try steward.emergencyLowerLiquidationLTV(c) {
            ++calls;
        } catch {}
    }

    function overrideCaps(uint256 seed, uint16 raw) external {
        (, IEVault escrow,) = _pick(seed);
        IPoppieRiskSteward.CapChange[] memory c = new IPoppieRiskSteward.CapChange[](1);
        c[0] = IPoppieRiskSteward.CapChange(address(escrow), uint16(bound(raw, 0, type(uint16).max)), 1);
        vm.prank(ops);
        try steward.overrideCaps(c) {
            ++calls;
        } catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 5 days));
    }
}

/// @notice After any sequence of steward calls:
/// - every listed asset's borrow LTV <= converged liquidation LTV <= its class ceilings, in every hub;
/// - a long-tail asset is borrowable only in its band hub;
/// - escrow borrow caps are raw 1; supply caps are never raw 0 and never above the cap ceiling;
/// - tightening never raised a current liquidation LTV nor shortened an active ramp.
contract StewardInvariants is StewardFixture {
    StewardHandler internal handler;

    function setUp() public override {
        super.setUp();
        IPoppieRiskSteward.RiskClass[6] memory classes = [
            IPoppieRiskSteward.RiskClass.BlueChip,
            IPoppieRiskSteward.RiskClass.BlueChip,
            IPoppieRiskSteward.RiskClass.BlueChip,
            IPoppieRiskSteward.RiskClass.M1,
            IPoppieRiskSteward.RiskClass.M2,
            IPoppieRiskSteward.RiskClass.M3
        ];
        IEVault[4] memory hs = _allHubs();
        address[] memory assets = new address[](6);
        IEVault[] memory escrows = new IEVault[](6);
        for (uint256 i; i < 6; ++i) {
            (assets[i], escrows[i]) = _listNew(classes[i], hs[uint8(classes[i])]);
        }
        IEVault[] memory hubs_ = new IEVault[](4);
        for (uint256 i; i < 4; ++i) {
            hubs_[i] = hs[i];
        }
        handler = new StewardHandler(steward, ops, tightener, loosener, assets, escrows, hubs_);
        targetContract(address(handler));
    }

    function invariant_ltvWithinCeilings() public view {
        IEVault[4] memory hs = _allHubs();
        for (uint256 i; i < handler.assetCount(); ++i) {
            address asset = handler.assets(i);
            IEVault escrow = handler.escrows(i);
            IPoppieRiskSteward.AssetInfo memory info = steward.assetInfo(asset);
            (uint16 ceilB, uint16 ceilL) = steward.classCeilings(info.riskClass);
            for (uint256 h; h < 4; ++h) {
                (uint16 b, uint16 target,,,) = hs[h].LTVFull(address(escrow));
                assertLe(b, target, "borrow > liquidation");
                assertLe(b, ceilB, "borrow > class ceiling");
                assertLe(target, ceilL, "liquidation target > class ceiling");
                if (info.riskClass != IPoppieRiskSteward.RiskClass.BlueChip && address(hs[h]) != info.bandHub) {
                    // Liquidation LTV may be non-zero there (a demotion ramp, possibly cancelled), never borrowable.
                    assertEq(b, 0, "long tail borrowable outside band hub");
                }
            }
        }
    }

    function invariant_escrowCaps() public view {
        for (uint256 i; i < handler.assetCount(); ++i) {
            IEVault escrow = handler.escrows(i);
            (uint16 s, uint16 b) = escrow.caps();
            (uint16 ceil,) = steward.capCeilings(address(escrow));
            assertEq(b, 1, "escrow borrow cap");
            assertTrue(s != 0, "raw 0 supply cap");
            assertLe(_resolve(s), _resolve(ceil), "supply cap above ceiling");
        }
    }

    function invariant_tighteningNeverLoosens() public view {
        assertEq(handler.tightenViolations(), 0);
    }

    /// @dev Guards against a handler that only ever reverts: every run of 32 calls lands some successful ones.
    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "no successful steward call in this run");
    }

    function _resolve(uint16 raw) internal pure returns (uint256) {
        if (raw == 0) return type(uint256).max;
        return 10 ** (raw & 63) * (raw >> 6) / 100;
    }
}
