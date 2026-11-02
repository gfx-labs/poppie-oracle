// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";
import {Errors as EVKErrors} from "evk/EVault/shared/Errors.sol";

import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {FullStackFixture} from "../harness/FullStackFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Steward changes against real, hooked hubs with real positions: ramps give borrowers time, blue-chip
/// sync, atomic promote, MS_OPS override and batched ramp cancel after stacked cuts, and steward caps enforced by
/// EVK.
contract StewardOnHubsIntegrationTest is FullStackFixture {
    address internal borrower = makeAddr("borrower");
    IEVault internal escrow;
    MockERC20 internal longTail;
    IEVault internal ltEscrow;

    function setUp() public override {
        super.setUp();
        escrow = _listAsset(address(stock), false, IPoppieRiskSteward.RiskClass.BlueChip, prime, 200e18);
        longTail = new MockERC20("Long Tail", "LT", 18);
        ltEscrow = _listAsset(address(longTail), false, IPoppieRiskSteward.RiskClass.M1, hubM1, 50e18);
        _depositCollateral(address(stock), borrower, 10e18, prime);
    }

    function _liqChange(IEVault hub, address asset, uint16 ltv, uint32 ramp)
        internal
        pure
        returns (IPoppieRiskSteward.LiquidationLtvChange[] memory c)
    {
        c = new IPoppieRiskSteward.LiquidationLtvChange[](1);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(address(hub), asset, ltv, ramp);
    }

    function _healthy(IEVault hub, address account) internal view returns (bool) {
        (uint256 collateralValue, uint256 liabilityValue) = hub.accountLiquidity(account, true);
        return collateralValue > liabilityValue;
    }

    function test_liquidationLtvCutRampsInGivingBorrowersTime() public {
        _borrow(prime, borrower, 690e6); // liquidation value at 37.5%: 750
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, address(stock), 3250, 72 hours)); // -> 650 at the end
        assertTrue(_healthy(prime, borrower), "healthy at the start of the ramp");

        _warpAndRefresh(36 hours); // liq LTV 35% -> 700 > 690
        assertTrue(_healthy(prime, borrower), "healthy mid-ramp");

        _warpAndRefresh(36 hours); // 32.5% -> 650 < 690
        assertFalse(_healthy(prime, borrower), "liquidatable at the end of the ramp");
        _liquidate(prime, borrower, escrow);
    }

    function test_borrowLtvCutDuringRampDoesNotAccelerateIt() public {
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, address(stock), 3250, 72 hours));
        _warpAndRefresh(10 hours);
        IPoppieRiskSteward.BorrowLtvChange[] memory b = new IPoppieRiskSteward.BorrowLtvChange[](1);
        b[0] = IPoppieRiskSteward.BorrowLtvChange(address(prime), address(stock), 1000);
        vm.prank(tightener);
        steward.lowerBorrowLTV(b);
        _warpAndRefresh(26 hours); // 36h in: halfway
        assertApproxEqAbs(prime.LTVLiquidation(address(escrow)), 3500, 1);
    }

    function test_blueChipSyncAcrossAllHubs() public {
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(hubM3, address(stock), 3500, 72 hours));
        IEVault[4] memory hs = _hubs();
        for (uint256 i; i < 4; ++i) {
            (uint16 b, uint16 t,, uint48 end,) = hs[i].LTVFull(address(escrow));
            assertEq(t, 3500);
            assertEq(b, 3000);
            assertEq(end, T0 + 72 hours);
        }
    }

    function test_promoteMakesLongTailBorrowableInEveryHubAtomically() public {
        address b2 = makeAddr("b2");
        _depositCollateral(address(longTail), b2, 100e18, prime);
        // Not collateral in Prime yet.
        assertEq(prime.LTVBorrow(address(ltEscrow)), 0);

        vm.prank(ops); // K_LOOSEN in phase 1
        steward.promote(address(longTail));
        IEVault[3] memory others = [prime, hubM2, hubM3];
        for (uint256 i; i < 3; ++i) {
            assertEq(others[i].LTVBorrow(address(ltEscrow)), 3500);
        }
        // 100 * 50 * 35% = 1,750.
        _borrow(prime, b2, 1_749e6);
    }

    function test_overrideAndBatchedRampCancelAfterStackedCuts() public {
        MockERC20 bc2 = new MockERC20("BC2", "BC2", 18);
        IEVault e2 = _listAsset(address(bc2), false, IPoppieRiskSteward.RiskClass.BlueChip, prime, 100e18);

        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](2);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(address(prime), address(stock), 3250, 72 hours);
        c[1] = IPoppieRiskSteward.LiquidationLtvChange(address(prime), address(bc2), 3250, 72 hours);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(c);
        _warpAndRefresh(24 hours);
        c[0].liquidationLtv = 3083;
        c[1].liquidationLtv = 3083;
        vm.prank(tightener);
        steward.lowerLiquidationLTV(c); // stacked mid-ramp

        // A mass tightening turns out to be wrong: MS_OPS restores borrow LTVs and cancels the ramps in one batch
        // each.
        IPoppieRiskSteward.BorrowLtvChange[] memory o = new IPoppieRiskSteward.BorrowLtvChange[](2);
        o[0] = IPoppieRiskSteward.BorrowLtvChange(address(prime), address(stock), 2500);
        o[1] = IPoppieRiskSteward.BorrowLtvChange(address(prime), address(bc2), 2500);
        IPoppieRiskSteward.RampRef[] memory r = new IPoppieRiskSteward.RampRef[](2);
        r[0] = IPoppieRiskSteward.RampRef(address(prime), address(stock));
        r[1] = IPoppieRiskSteward.RampRef(address(prime), address(bc2));
        vm.startPrank(ops);
        steward.cancelRamp(r);
        steward.overrideLTV(o);
        vm.stopPrank();

        IEVault[4] memory hs = _hubs();
        for (uint256 i; i < 4; ++i) {
            assertEq(hs[i].LTVLiquidation(address(escrow)), 3750);
            assertEq(hs[i].LTVLiquidation(address(e2)), 3750);
            assertEq(hs[i].LTVBorrow(address(escrow)), 2500);
        }
    }

    function test_demoteRemovesBorrowingPowerOutsideBandHub() public {
        vm.prank(tightener);
        steward.demote(address(stock), IPoppieRiskSteward.RiskClass.M1, address(hubM1));
        assertEq(prime.LTVBorrow(address(escrow)), 0);
        assertEq(hubM1.LTVBorrow(address(escrow)), 3500);
        // The borrower's existing collateral in Prime gives no new borrowing power...
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        this.borrowExternal(prime, borrower, 1e6);
        // ...but liquidation LTV ramps down over 7.5 days, so existing positions are not liquidated at once.
        assertEq(prime.LTVLiquidation(address(escrow)), 3750);
    }

    function borrowExternal(IEVault h, address account, uint256 amount) external {
        _borrow(h, account, amount);
    }

    function test_stewardSupplyCapEnforcedByEvk() public {
        // Launch supply cap: 25% of the 1e27 ceiling = 2.5e26. Lower it to 100 tokens, then hit it.
        IPoppieRiskSteward.CapChange[] memory cc = new IPoppieRiskSteward.CapChange[](1);
        cc[0] = IPoppieRiskSteward.CapChange(address(ltEscrow), steward_encode(100e18), 1);
        vm.prank(tightener);
        steward.lowerCaps(cc);

        address d = makeAddr("depositor");
        longTail.mint(d, 200e18);
        vm.startPrank(d);
        longTail.approve(address(ltEscrow), type(uint256).max);
        vm.expectRevert(EVKErrors.E_SupplyCapExceeded.selector);
        ltEscrow.deposit(100e18, d); // 1 seed + 100 > 100
        ltEscrow.deposit(99e18, d);
        vm.stopPrank();

        cc[0].supplyCap = steward_encode(1_000e18);
        vm.prank(ops);
        steward.raiseCaps(cc);
        vm.prank(d);
        ltEscrow.deposit(100e18, d);
    }

    function test_escrowBorrowCapStaysZero() public {
        (, uint16 borrowCap) = escrow.caps();
        assertEq(borrowCap, 1);
    }
}
