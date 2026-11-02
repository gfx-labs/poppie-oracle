// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IEVault, IGovernance} from "evk/EVault/IEVault.sol";

import {PoppieRiskSteward} from "../../src/steward/PoppieRiskSteward.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";
import {MS_OPS, K_TIGHTEN, K_LOOSEN} from "../../src/access/Roles.sol";

import {StewardFixture} from "../harness/StewardFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWrapper} from "../mocks/MockEscrowDeps.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PoppieRiskStewardTest is StewardFixture {
    IPoppieRiskSteward.RiskClass internal constant BC = IPoppieRiskSteward.RiskClass.BlueChip;
    IPoppieRiskSteward.RiskClass internal constant M1 = IPoppieRiskSteward.RiskClass.M1;
    IPoppieRiskSteward.RiskClass internal constant M2 = IPoppieRiskSteward.RiskClass.M2;
    IPoppieRiskSteward.RiskClass internal constant M3 = IPoppieRiskSteward.RiskClass.M3;

    uint32 internal constant H72 = 72 hours;

    // -- Helpers --------------------------------------------------------------------------------

    /// @dev Set an LTV directly through the governor (test-only holder of the setLTV selector role), ramp 0.
    function _force(IEVault hub, IEVault escrow, uint16 b, uint16 l) internal {
        if (!governor.hasRole(bytes32(IGovernance.setLTV.selector), address(this))) {
            vm.prank(admin);
            governor.grantRole(bytes32(IGovernance.setLTV.selector), address(this));
        }
        (bool ok,) = address(governor)
            .call(abi.encodePacked(abi.encodeCall(IGovernance.setLTV, (address(escrow), b, l, 0)), address(hub)));
        require(ok, "force");
    }

    function _forceAll(IEVault escrow, uint16 b, uint16 l) internal {
        IEVault[4] memory hs = _allHubs();
        for (uint256 i; i < 4; ++i) {
            _force(hs[i], escrow, b, l);
        }
    }

    function _expectUnauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    // -- Construction, hubs, views --------------------------------------------------------------

    function test_constructorRejectsZero() public {
        vm.expectRevert(IPoppieRiskSteward.ZeroAddress.selector);
        new PoppieRiskSteward(admin, address(0));
        vm.expectRevert(IPoppieRiskSteward.ZeroAddress.selector);
        new PoppieRiskSteward(address(0), address(governor));
    }

    function test_hubsAndBands() public view {
        address[] memory h = steward.hubs();
        assertEq(h.length, 4);
        assertEq(h[0], address(prime));
        assertEq(h[3], address(hubM3));
        assertEq(uint8(steward.hubBand(address(prime))), uint8(BC));
        assertEq(uint8(steward.hubBand(address(hubM2))), uint8(M2));
    }

    function test_hubBandUnknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownHub.selector, address(1)));
        steward.hubBand(address(1));
    }

    function test_addHubOnlyAdminOnceNonZero() public {
        _expectUnauthorized(ops, 0x00);
        vm.prank(ops);
        steward.addHub(address(1), M1);

        vm.startPrank(admin);
        vm.expectRevert(IPoppieRiskSteward.ZeroAddress.selector);
        steward.addHub(address(0), M1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.WrongBand.selector, address(prime), BC));
        steward.addHub(address(prime), M1);
        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.HubAdded(address(1), M2);
        steward.addHub(address(1), M2);
        vm.stopPrank();
        assertEq(steward.hubs().length, 5);
    }

    function test_classCeilings() public view {
        (uint16 b, uint16 l) = steward.classCeilings(BC);
        assertEq(b, 7000);
        assertEq(l, 7500);
        (b, l) = steward.classCeilings(M1);
        assertEq(b, 5000);
        assertEq(l, 5800);
        (b, l) = steward.classCeilings(M2);
        assertEq(b, 4500);
        assertEq(l, 5200);
        (b, l) = steward.classCeilings(M3);
        assertEq(b, 3500);
        assertEq(l, 4200);
    }

    // -- AmountCap encoding ---------------------------------------------------------------------

    function test_encodeCapDownNeverRawZeroAndRoundsDown() public view {
        assertEq(steward.encodeCapDown(0), 1);
        assertEq(_resolveRaw(steward.encodeCapDown(0)), 0);
        assertEq(_resolveRaw(steward.encodeCapDown(1)), 1);
        assertEq(_resolveRaw(steward.encodeCapDown(1_000_000e18)), 1_000_000e18);
        assertEq(_resolveRaw(steward.encodeCapDown(123_456_789)), 123_000_000);
    }

    function testFuzz_encodeCapDown(uint128 amount) public view {
        uint16 raw = steward.encodeCapDown(amount);
        assertTrue(raw != 0);
        uint256 r = _resolveRaw(raw);
        assertLe(r, amount);
        // The mantissa keeps at least 3 significant digits, so the loss is under 1%.
        assertGe(r + uint256(amount) / 100 + 1, amount);
    }

    function _resolveRaw(uint16 raw) internal pure returns (uint256) {
        if (raw == 0) return type(uint256).max;
        return 10 ** (raw & 63) * (raw >> 6) / 100;
    }

    // -- list -----------------------------------------------------------------------------------

    function test_listBlueChipInEveryHubAtLaunchLimits() public {
        (address token, IEVault escrow) = _newEscrow();
        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.Listed(token, address(escrow), address(hubM2), BC);
        _list(token, address(escrow), address(hubM2), BC);

        IEVault[4] memory hs = _allHubs();
        for (uint256 i; i < 4; ++i) {
            assertEq(_borrowLtv(hs[i], escrow), 3500);
            assertEq(_liqLtv(hs[i], escrow), 3750);
        }
        IPoppieRiskSteward.AssetInfo memory info = steward.assetInfo(token);
        assertEq(info.escrow, address(escrow));
        assertEq(info.wrapper, address(0));
        assertEq(info.bandHub, address(0));
        assertTrue(info.listed);
        assertEq(uint8(info.riskClass), uint8(BC));
    }

    function test_listLongTailOnlyInBandHub() public {
        (address token, IEVault escrow) = _listNew(M2, hubM2);
        assertEq(_borrowLtv(hubM2, escrow), 2250);
        assertEq(_liqLtv(hubM2, escrow), 2600);
        assertEq(_liqLtv(prime, escrow), 0);
        assertEq(_liqLtv(hubM1, escrow), 0);
        assertEq(steward.assetInfo(token).bandHub, address(hubM2));
    }

    function test_listLaunchValuesPerClass() public {
        (, IEVault e1) = _listNew(M1, hubM1);
        (, IEVault e3) = _listNew(M3, hubM3);
        assertEq(_borrowLtv(hubM1, e1), 2500);
        assertEq(_liqLtv(hubM1, e1), 2900);
        assertEq(_borrowLtv(hubM3, e3), 1750);
        assertEq(_liqLtv(hubM3, e3), 2100);
    }

    function test_listSetsSupplyCapToQuarterCeilingAndBorrowRawOne() public {
        (, IEVault escrow) = _listNew(M1, hubM1);
        (uint16 s, uint16 b) = escrow.caps();
        assertEq(_resolveRaw(s), 250_000e18);
        assertEq(b, 1);
    }

    function test_listRoundsSupplyCapDown() public {
        (address token, IEVault escrow) = _newEscrow();
        // Ceiling 1.23e24: a quarter is 3.075e23, which needs 4 significant digits; rounds down to 3.07e23.
        _setCeiling(address(escrow), steward.encodeCapDown(1_230_000e18), 1);
        _list(token, address(escrow), address(hubM1), M1);
        (uint16 s,) = escrow.caps();
        assertEq(_resolveRaw(s), 307_000e18);
    }

    function test_listWrappedAsset() public {
        MockERC20 token = new MockERC20("Rebasing", "RB", 18);
        MockWrapper wrapper = new MockWrapper(IERC20(address(token)));
        IEVault escrow = _createEscrow(address(wrapper));
        escrow.setGovernorAdmin(address(governor));
        _setCeiling(address(escrow), escrowSupplyCeiling, 1);
        _list(address(token), address(escrow), address(hubM1), M1);
        assertEq(steward.assetInfo(address(token)).wrapper, address(wrapper));
    }

    function test_listRejectsEscrowOfAnotherToken() public {
        MockERC20 other = new MockERC20("Other", "O", 18);
        MockWrapper wrapper = new MockWrapper(IERC20(address(other)));
        IEVault escrow = _createEscrow(address(wrapper));
        _setCeiling(address(escrow), escrowSupplyCeiling, 1);
        address token = address(new MockERC20("T", "T", 18));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownVault.selector, address(escrow)));
        _list(token, address(escrow), address(hubM1), M1);
    }

    function test_listRequiresCeiling() public {
        address token = address(new MockERC20("T", "T", 18));
        IEVault escrow = _createEscrow(token);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.CapCeilingNotSet.selector, address(escrow)));
        _list(token, address(escrow), address(hubM1), M1);
    }

    function test_listRejectsWrongBandUnknownHubAndDuplicates() public {
        (address token, IEVault escrow) = _newEscrow();
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.WrongBand.selector, address(hubM2), M1));
        _list(token, address(escrow), address(hubM2), M1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownHub.selector, address(7)));
        _list(token, address(escrow), address(7), M1);
        vm.expectRevert(IPoppieRiskSteward.ZeroAddress.selector);
        _list(address(0), address(escrow), address(hubM1), M1);

        _list(token, address(escrow), address(hubM1), M1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.AlreadyListed.selector, token));
        _list(token, address(escrow), address(hubM1), M1);
        // Same escrow under another asset address.
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.AlreadyListed.selector, address(9)));
        _list(address(9), address(escrow), address(hubM1), M1);
    }

    function test_listOnlyOps() public {
        IPoppieRiskSteward.Listing[] memory l = new IPoppieRiskSteward.Listing[](0);
        _expectUnauthorized(tightener, MS_OPS);
        vm.prank(tightener);
        steward.list(l);
    }

    // -- setCapCeiling --------------------------------------------------------------------------

    function test_setCapCeilingRules() public {
        vm.startPrank(ops);
        IPoppieRiskSteward.CapCeilingChange[] memory c = new IPoppieRiskSteward.CapCeilingChange[](1);
        c[0] = IPoppieRiskSteward.CapCeilingChange(address(5), 0, 1);
        vm.expectRevert(IPoppieRiskSteward.ZeroCapNotAllowed.selector);
        steward.setCapCeiling(c);
        c[0] = IPoppieRiskSteward.CapCeilingChange(address(5), 1, 0);
        vm.expectRevert(IPoppieRiskSteward.ZeroCapNotAllowed.selector);
        steward.setCapCeiling(c);
        c[0] = IPoppieRiskSteward.CapCeilingChange(address(0), 1, 1);
        vm.expectRevert(IPoppieRiskSteward.ZeroAddress.selector);
        steward.setCapCeiling(c);
        // Unlisted vault accepted.
        c[0] = IPoppieRiskSteward.CapCeilingChange(address(5), 100, 1);
        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.CapCeilingSet(address(5), 100, 1);
        steward.setCapCeiling(c);
        vm.stopPrank();
        (uint16 s, uint16 b) = steward.capCeilings(address(5));
        assertEq(s, 100);
        assertEq(b, 1);

        _expectUnauthorized(loosener, MS_OPS);
        vm.prank(loosener);
        steward.setCapCeiling(c);
    }

    function test_loweringCeilingDoesNotLowerCaps() public {
        (, IEVault escrow) = _listNew(M1, hubM1);
        (uint16 before,) = escrow.caps();
        _setCeiling(address(escrow), steward.encodeCapDown(1e18), 1);
        (uint16 afterS,) = escrow.caps();
        assertEq(afterS, before);
    }

    // -- lowerBorrowLTV -------------------------------------------------------------------------

    function test_lowerBorrowAnyAmountInstant() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        vm.prank(tightener);
        steward.lowerBorrowLTV(_borrowChange(hubM1, token, 0));
        assertEq(_borrowLtv(hubM1, escrow), 0);
        assertEq(_liqLtv(hubM1, escrow), 2900);
    }

    function test_lowerBorrowRejectsNonLowering() public {
        (address token,) = _listNew(M1, hubM1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotALowering.selector, address(hubM1), token));
        vm.prank(tightener);
        steward.lowerBorrowLTV(_borrowChange(hubM1, token, 2500));
    }

    function test_lowerBorrowBlueChipSyncsAllHubs() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerBorrowLTV(_borrowChange(hubM3, token, 1000));
        IEVault[4] memory hs = _allHubs();
        for (uint256 i; i < 4; ++i) {
            assertEq(_borrowLtv(hs[i], escrow), 1000);
        }
    }

    function test_longTailEntryMustNameBandHub() public {
        (address token,) = _listNew(M1, hubM1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.WrongBand.selector, address(prime), M1));
        vm.prank(tightener);
        steward.lowerBorrowLTV(_borrowChange(prime, token, 0));
    }

    function test_unknownHubAndAsset() public {
        (address token,) = _listNew(M1, hubM1);
        vm.startPrank(tightener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownHub.selector, address(3)));
        steward.lowerBorrowLTV(_borrowChange(IEVault(address(3)), token, 0));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownAsset.selector, address(4)));
        steward.lowerBorrowLTV(_borrowChange(hubM1, address(4), 0));
        vm.stopPrank();
    }

    function test_tightenOnlyKTighten() public {
        (address token,) = _listNew(M1, hubM1);
        _expectUnauthorized(loosener, K_TIGHTEN);
        vm.prank(loosener);
        steward.lowerBorrowLTV(_borrowChange(hubM1, token, 0));
        _expectUnauthorized(ops, K_TIGHTEN);
        vm.prank(ops);
        steward.lowerLiquidationLTV(_liqChange(hubM1, token, 2400, H72));
        _expectUnauthorized(ops, K_TIGHTEN);
        vm.prank(ops);
        steward.demote(token, M1, address(hubM1));
    }

    // -- lowerLiquidationLTV --------------------------------------------------------------------

    function test_cutStepBoundary() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.StepTooLarge.selector, address(prime), token, 501, 500)
        );
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3249, H72));

        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        (uint16 target, uint48 end) = _liqTarget(prime, escrow);
        assertEq(target, 3250);
        assertEq(end, START + H72);
        assertEq(_liqLtv(prime, escrow), 3750); // ramp starts at the old value
    }

    function test_cutRampBoundary() public {
        (address token,) = _listNew(BC, prime);
        vm.prank(tightener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.RampTooShort.selector, address(prime), token, H72 - 1, H72)
        );
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3500, H72 - 1));
    }

    function test_cutOncePerAssetPerHubPer24h() public {
        (address token,) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3700, H72));

        vm.warp(START + 24 hours - 1);
        vm.prank(tightener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.RateLimited.selector, address(prime), token, uint40(START + 24 hours)
            )
        );
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3600, H72));

        vm.warp(START + 24 hours);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3600, H72));
    }

    function test_cutRateLimitIsPerHub() public {
        (address t1,) = _listNew(M1, hubM1);
        (address t2,) = _listNew(M2, hubM2);
        vm.startPrank(tightener);
        steward.lowerLiquidationLTV(_liqChange(hubM1, t1, 2800, H72));
        steward.lowerLiquidationLTV(_liqChange(hubM2, t2, 2500, H72));
        vm.stopPrank();
    }

    function test_cutRejectsNonLowering() public {
        (address token,) = _listNew(M1, hubM1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotALowering.selector, address(hubM1), token));
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(hubM1, token, 2900, H72));
    }

    function test_cutLowersBorrowToKeepGap() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        assertEq(_borrowLtv(prime, escrow), 2750);
        (address lt, IEVault e2) = _listNew(M1, hubM1);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(hubM1, lt, 2400, H72));
        assertEq(_borrowLtv(hubM1, e2), 1600);
    }

    function test_cutKeepsLowerBorrow() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.startPrank(tightener);
        steward.lowerBorrowLTV(_borrowChange(prime, token, 1000));
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        vm.stopPrank();
        assertEq(_borrowLtv(prime, escrow), 1000);
    }

    function test_cutStepMeasuredFromRampedValue() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        vm.warp(START + 24 hours);
        uint16 now_ = _liqLtv(prime, escrow); // 3250 + 500 * 48/72 = 3583
        assertEq(now_, 3583);
        vm.prank(tightener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.StepTooLarge.selector, address(prime), token, 501, 500)
        );
        steward.lowerLiquidationLTV(_liqChange(prime, token, now_ - 501, H72));
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, now_ - 500, H72));
    }

    function test_cutRampNeverShorterThanRemaining() public {
        (address token,) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3700, 200 hours));
        vm.warp(START + 24 hours);
        vm.prank(tightener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.RampTooShort.selector, address(prime), token, H72, uint32(176 hours)
            )
        );
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3650, H72));
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3650, 176 hours));
    }

    function test_borrowChangesNeverShortenActiveRamp() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        (, uint48 end) = _liqTarget(prime, escrow);

        vm.warp(START + 10 hours);
        uint16 expectedAt30h = 3250 + uint16(uint256(500) * 42 / 72);
        vm.prank(tightener);
        steward.lowerBorrowLTV(_borrowChange(prime, token, 2000));
        vm.prank(ops);
        steward.overrideLTV(_borrowChange(prime, token, 2500));

        (uint16 target, uint48 end2) = _liqTarget(prime, escrow);
        assertEq(target, 3250);
        assertEq(end2, end);
        vm.warp(START + 30 hours);
        assertApproxEqAbs(_liqLtv(prime, escrow), expectedAt30h, 1);
        vm.warp(end);
        assertEq(_liqLtv(prime, escrow), 3250);
    }

    function test_cutBlueChipSyncsAllHubsWithBaseline() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(hubM2, token, 3500, H72));
        IEVault[4] memory hs = _allHubs();
        for (uint256 i; i < 4; ++i) {
            (uint16 target,) = _liqTarget(hs[i], escrow);
            assertEq(target, 3500);
            assertEq(steward.liquidationLtvBaseline(address(hs[i]), token), 3750);
        }
    }

    function test_blueChipDuplicateEntryHitsRateLimit() public {
        (address token,) = _listNew(BC, prime);
        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](2);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(address(prime), token, 3700, H72);
        c[1] = IPoppieRiskSteward.LiquidationLtvChange(address(hubM1), token, 3650, H72);
        vm.prank(tightener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.RateLimited.selector, address(prime), token, uint40(START + 24 hours)
            )
        );
        steward.lowerLiquidationLTV(c);
    }

    /// @dev Q5: the "<= 10 assets per 24h" budget is removed.
    function test_removedLimit_noDailyAssetBudget() public {
        uint256 n = 15;
        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](n);
        for (uint256 i; i < n; ++i) {
            (address token,) = _listNew(M1, hubM1);
            c[i] = IPoppieRiskSteward.LiquidationLtvChange(address(hubM1), token, 2400, H72);
        }
        vm.prank(tightener);
        steward.lowerLiquidationLTV(c);
    }

    // -- emergencyLowerLiquidationLTV -----------------------------------------------------------

    function test_emergencyBounds() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.startPrank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.StepTooLarge.selector, address(prime), token, 1501, 1500)
        );
        steward.emergencyLowerLiquidationLTV(_liqChange(prime, token, 2249, 12 hours));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.RampTooShort.selector, address(prime), token, uint32(12 hours - 1), uint32(12 hours)
            )
        );
        steward.emergencyLowerLiquidationLTV(_liqChange(prime, token, 2250, 12 hours - 1));
        steward.emergencyLowerLiquidationLTV(_liqChange(prime, token, 2250, 12 hours));
        vm.stopPrank();
        (uint16 target,) = _liqTarget(prime, escrow);
        assertEq(target, 2250);
        assertEq(_borrowLtv(prime, escrow), 1750);
    }

    function test_emergencyHasNoRateLimitAndDoesNotConsumeTightenLimit() public {
        (address token,) = _listNew(BC, prime);
        vm.startPrank(ops);
        steward.emergencyLowerLiquidationLTV(_liqChange(prime, token, 3000, 12 hours));
        vm.warp(START + 1 hours);
        steward.emergencyLowerLiquidationLTV(_liqChange(prime, token, 2500, 12 hours));
        vm.stopPrank();
        // Emergency ramp has ended (13h); a K_TIGHTEN cut is still allowed within 24h of the emergency cuts.
        vm.warp(START + 13 hours);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 2400, H72));
    }

    function test_emergencyOnlyOps() public {
        (address token,) = _listNew(BC, prime);
        _expectUnauthorized(tightener, MS_OPS);
        vm.prank(tightener);
        steward.emergencyLowerLiquidationLTV(_liqChange(prime, token, 3500, 12 hours));
    }

    // -- cancelRamp -----------------------------------------------------------------------------

    function test_stackedCutsThenCancelRestoresChainBaseline() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        vm.warp(START + 24 hours);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3083, H72));
        assertEq(steward.liquidationLtvBaseline(address(prime), token), 3750);

        vm.warp(START + 30 hours);
        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.RampCancelled(address(prime), token, 3750);
        vm.prank(ops);
        steward.cancelRamp(_rampRef(hubM1, token));

        IEVault[4] memory hs = _allHubs();
        for (uint256 i; i < 4; ++i) {
            assertEq(_liqLtv(hs[i], escrow), 3750);
            (uint16 target,) = _liqTarget(hs[i], escrow);
            assertEq(target, 3750);
            assertEq(steward.liquidationLtvBaseline(address(hs[i]), token), 0);
        }
    }

    function test_cancelRampNeedsActiveRamp() public {
        (address token,) = _listNew(BC, prime);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NoActiveRamp.selector, address(prime), token));
        steward.cancelRamp(_rampRef(prime, token));

        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3500, H72));
        vm.warp(START + H72);
        assertEq(steward.liquidationLtvBaseline(address(prime), token), 0);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NoActiveRamp.selector, address(prime), token));
        steward.cancelRamp(_rampRef(prime, token));
    }

    function test_newChainAfterRampEndsRecordsNewBaseline() public {
        (address token,) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3500, H72));
        vm.warp(START + H72);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3300, H72));
        assertEq(steward.liquidationLtvBaseline(address(prime), token), 3500);
    }

    function test_cancelRampOnlyOps() public {
        (address token,) = _listNew(BC, prime);
        _expectUnauthorized(tightener, MS_OPS);
        vm.prank(tightener);
        steward.cancelRamp(_rampRef(prime, token));
    }

    // -- raiseLTV -------------------------------------------------------------------------------

    function test_raiseStepBoundary() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 4000, 5000);
        vm.prank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.StepTooLarge.selector, address(hubM1), token, 301, 300)
        );
        steward.raiseLTV(_raise(hubM1, token, 4000, 5301));
        vm.prank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.StepTooLarge.selector, address(hubM1), token, 301, 300)
        );
        steward.raiseLTV(_raise(hubM1, token, 4301, 5300));

        vm.prank(loosener);
        steward.raiseLTV(_raise(hubM1, token, 4300, 5300));
        assertEq(_borrowLtv(hubM1, escrow), 4300);
        assertEq(_liqLtv(hubM1, escrow), 5300);
    }

    function test_raiseOncePerAssetPer7Days() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 3000, 4000);
        vm.prank(loosener);
        steward.raiseLTV(_raise(hubM1, token, 3100, 4100));
        vm.warp(START + 7 days - 1);
        vm.prank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.RateLimited.selector, address(hubM1), token, uint40(START + 7 days)
            )
        );
        steward.raiseLTV(_raise(hubM1, token, 3200, 4200));
        vm.warp(START + 7 days);
        vm.prank(loosener);
        steward.raiseLTV(_raise(hubM1, token, 3200, 4200));
    }

    function test_raiseClassCeilingBoundary() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 4800, 5700);
        vm.prank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.ExceedsClassCeiling.selector, address(hubM1), token, 5001, 5000)
        );
        steward.raiseLTV(_raise(hubM1, token, 5001, 5800));
        vm.prank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.ExceedsClassCeiling.selector, address(hubM1), token, 5801, 5800)
        );
        steward.raiseLTV(_raise(hubM1, token, 4800, 5801));
        vm.prank(loosener);
        steward.raiseLTV(_raise(hubM1, token, 5000, 5800));
    }

    function test_raiseGapRuleBoundary() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 4000, 4800);
        vm.prank(loosener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.GapRuleViolated.selector, address(hubM1), token));
        steward.raiseLTV(_raise(hubM1, token, 4001, 4800));
        vm.prank(loosener);
        steward.raiseLTV(_raise(hubM1, token, 4200, 5000));

        (address bc, IEVault e2) = _listNew(BC, prime);
        _forceAll(e2, 3000, 3500);
        vm.prank(loosener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.GapRuleViolated.selector, address(prime), bc));
        steward.raiseLTV(_raise(prime, bc, 3001, 3500));
        vm.prank(loosener);
        steward.raiseLTV(_raise(prime, bc, 3000, 3500 + 1)); // liquidation only
    }

    function test_raiseLiquidationOnlyWithLaunchGapAllowed() public {
        // Launch values (35/37.5) sit inside the 5 pt gap; raising only the liquidation LTV is allowed.
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(loosener);
        steward.raiseLTV(_raise(prime, token, 3500, 3800));
        assertEq(_liqLtv(hubM3, escrow), 3800);
    }

    function test_raiseRejectsNonRaiseAndBorrowAboveLiq() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 2000, 2900);
        vm.startPrank(loosener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotARaise.selector, address(hubM1), token));
        steward.raiseLTV(_raise(hubM1, token, 2000, 2900));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotARaise.selector, address(hubM1), token));
        steward.raiseLTV(_raise(hubM1, token, 1999, 3000));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotARaise.selector, address(hubM1), token));
        steward.raiseLTV(_raise(hubM1, token, 2000, 2800));
        vm.stopPrank();

        _force(hubM1, escrow, 2900, 2900);
        vm.prank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.BorrowLtvAboveLiquidationLtv.selector, address(hubM1), token)
        );
        steward.raiseLTV(_raise(hubM1, token, 3000, 2900));
    }

    function test_raiseLiquidationDuringRampIsInstantAndEndsChain() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.prank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        vm.warp(START + 36 hours); // current 3500
        vm.prank(loosener);
        steward.raiseLTV(_raise(prime, token, 2750, 3800));
        assertEq(_liqLtv(prime, escrow), 3800);
        assertEq(steward.liquidationLtvBaseline(address(prime), token), 0);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NoActiveRamp.selector, address(prime), token));
        steward.cancelRamp(_rampRef(prime, token));
    }

    function test_raiseBorrowOnlyDuringRampKeepsRamp() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        vm.startPrank(tightener);
        steward.lowerLiquidationLTV(_liqChange(prime, token, 3250, H72));
        steward.lowerBorrowLTV(_borrowChange(prime, token, 2500));
        vm.stopPrank();
        (, uint48 end) = _liqTarget(prime, escrow);
        vm.warp(START + 1 hours);
        vm.prank(loosener);
        steward.raiseLTV(_raise(prime, token, 2750, 3250));
        (uint16 target, uint48 end2) = _liqTarget(prime, escrow);
        assertEq(target, 3250);
        assertEq(end2, end);
        assertEq(_borrowLtv(prime, escrow), 2750);
        assertEq(steward.liquidationLtvBaseline(address(prime), token), 3750);
    }

    function test_loosenOnlyKLoosen() public {
        (address token,) = _listNew(M1, hubM1);
        _expectUnauthorized(tightener, K_LOOSEN);
        vm.prank(tightener);
        steward.raiseLTV(_raise(hubM1, token, 2600, 2900));
        _expectUnauthorized(ops, K_LOOSEN);
        vm.prank(ops);
        steward.promote(token);
    }

    // -- overrideLTV ----------------------------------------------------------------------------

    function test_overrideNoWeeklyLimitWithinCeilingAndGap() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 4000, 5000);
        vm.startPrank(ops);
        steward.overrideLTV(_borrowChange(hubM1, token, 4100));
        steward.overrideLTV(_borrowChange(hubM1, token, 4200));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.GapRuleViolated.selector, address(hubM1), token));
        steward.overrideLTV(_borrowChange(hubM1, token, 4201));
        steward.overrideLTV(_borrowChange(hubM1, token, 100));
        vm.stopPrank();
        assertEq(_borrowLtv(hubM1, escrow), 100);
    }

    function test_overrideCeilingAndLiqBound() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        _force(hubM1, escrow, 5000, 5800);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.ExceedsClassCeiling.selector, address(hubM1), token, 5001, 5000)
        );
        steward.overrideLTV(_borrowChange(hubM1, token, 5001));

        _force(hubM1, escrow, 2000, 3000);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.BorrowLtvAboveLiquidationLtv.selector, address(hubM1), token)
        );
        steward.overrideLTV(_borrowChange(hubM1, token, 3001));
    }

    function test_overrideDoesNotRaiseLiquidation() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        vm.prank(ops);
        steward.overrideLTV(_borrowChange(hubM1, token, 2000));
        assertEq(_liqLtv(hubM1, escrow), 2900);
    }

    function test_overrideOnlyOps() public {
        (address token,) = _listNew(M1, hubM1);
        _expectUnauthorized(loosener, MS_OPS);
        vm.prank(loosener);
        steward.overrideLTV(_borrowChange(hubM1, token, 2000));
    }

    // -- Caps -----------------------------------------------------------------------------------

    function test_lowerCapsDownToUsage() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        MockERC20(token).mint(address(this), 1000e18);
        IERC20(token).approve(address(escrow), 1000e18);
        escrow.deposit(1000e18, address(this));

        uint16 below = steward.encodeCapDown(999e18);
        vm.prank(tightener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.BelowCurrentUsage.selector, address(escrow), below));
        steward.lowerCaps(_caps(address(escrow), below, 1));

        uint16 atUsage = steward.encodeCapDown(1000e18);
        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.CapsSet(address(escrow), atUsage, 1, tightener);
        vm.prank(tightener);
        steward.lowerCaps(_caps(address(escrow), atUsage, 1));
        (uint16 s,) = escrow.caps();
        assertEq(s, atUsage);
    }

    function test_lowerCapsRules() public {
        (, IEVault escrow) = _listNew(M1, hubM1);
        (uint16 cur,) = escrow.caps();
        vm.startPrank(tightener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotALowering.selector, address(escrow), address(0)));
        steward.lowerCaps(_caps(address(escrow), cur, 1));
        vm.expectRevert(IPoppieRiskSteward.ZeroCapNotAllowed.selector);
        steward.lowerCaps(_caps(address(escrow), 0, 1));
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.EscrowBorrowCapMustStayZero.selector, address(escrow))
        );
        steward.lowerCaps(_caps(address(escrow), 1, 2));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownVault.selector, address(8)));
        steward.lowerCaps(_caps(address(8), 1, 1));
        // Down to "zero" (raw 1) with no usage.
        steward.lowerCaps(_caps(address(escrow), 1, 1));
        vm.stopPrank();
    }

    function test_hubCapsSameRules() public {
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(prime), 1000e6);
        prime.deposit(1000e6, address(this));

        (uint16 s, uint16 b) = prime.caps();
        vm.startPrank(tightener);
        uint16 tooLow = steward.encodeCapDown(999e6);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.BelowCurrentUsage.selector, address(prime), tooLow));
        steward.lowerCaps(_caps(address(prime), tooLow, b));
        steward.lowerCaps(_caps(address(prime), steward.encodeCapDown(1000e6), 1));
        vm.stopPrank();

        uint16 overBorrow = steward.encodeCapDown(51_000_000e6);
        vm.startPrank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.ExceedsCapCeiling.selector, address(prime), overBorrow, hubBorrowCeiling
            )
        );
        steward.raiseCaps(_caps(address(prime), s, overBorrow));
        steward.raiseCaps(_caps(address(prime), hubSupplyCeiling, hubBorrowCeiling));
        vm.stopPrank();
        (s, b) = prime.caps();
        assertEq(s, hubSupplyCeiling);
        assertEq(b, hubBorrowCeiling);
    }

    function test_raiseCapsCeilingBoundary() public {
        (, IEVault escrow) = _listNew(M1, hubM1);
        uint16 over = steward.encodeCapDown(1_010_000e18);
        vm.startPrank(loosener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.ExceedsCapCeiling.selector, address(escrow), over, escrowSupplyCeiling
            )
        );
        steward.raiseCaps(_caps(address(escrow), over, 1));
        steward.raiseCaps(_caps(address(escrow), escrowSupplyCeiling, 1));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotARaise.selector, address(escrow), address(0)));
        steward.raiseCaps(_caps(address(escrow), escrowSupplyCeiling, 1));
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRiskSteward.EscrowBorrowCapMustStayZero.selector, address(escrow))
        );
        steward.raiseCaps(_caps(address(escrow), escrowSupplyCeiling, 100));
        vm.stopPrank();
    }

    /// @dev Q6: the "+25% per 7 days" cap limit is removed; only the ceiling binds K_LOOSEN.
    function test_removedLimit_noCapRaiseRateLimit() public {
        (, IEVault escrow) = _listNew(M1, hubM1);
        vm.startPrank(loosener);
        steward.raiseCaps(_caps(address(escrow), steward.encodeCapDown(600_000e18), 1)); // +140%
        steward.raiseCaps(_caps(address(escrow), steward.encodeCapDown(900_000e18), 1)); // same block
        vm.stopPrank();
    }

    function test_raiseCapsNeedsCeiling() public {
        IEVault h = _createHub();
        uint16 small = steward.encodeCapDown(100e6);
        uint16 bigger = steward.encodeCapDown(200e6);
        h.setCaps(small, small);
        h.setGovernorAdmin(address(governor));
        vm.prank(admin);
        steward.addHub(address(h), M1);
        vm.prank(loosener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.CapCeilingNotSet.selector, address(h)));
        steward.raiseCaps(_caps(address(h), bigger, bigger));
    }

    function test_overrideCapsAnywhereUpToCeiling() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        MockERC20(token).mint(address(this), 1000e18);
        IERC20(token).approve(address(escrow), 1000e18);
        escrow.deposit(1000e18, address(this));
        vm.startPrank(ops);
        steward.overrideCaps(_caps(address(escrow), 1, 1)); // below usage
        steward.overrideCaps(_caps(address(escrow), escrowSupplyCeiling, 1));
        vm.stopPrank();
        uint16 over = steward.encodeCapDown(1_010_000e18);
        vm.startPrank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRiskSteward.ExceedsCapCeiling.selector, address(escrow), over, escrowSupplyCeiling
            )
        );
        steward.overrideCaps(_caps(address(escrow), over, 1));
        vm.stopPrank();
    }

    // -- promote --------------------------------------------------------------------------------

    function test_promoteListsInOtherHubsAndKeepsBandHub() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        (uint16 capBefore,) = escrow.caps();
        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.Promoted(token);
        vm.prank(loosener);
        steward.promote(token);

        assertEq(_borrowLtv(hubM1, escrow), 2500);
        assertEq(_liqLtv(hubM1, escrow), 2900);
        IEVault[3] memory others = [prime, hubM2, hubM3];
        for (uint256 i; i < 3; ++i) {
            assertEq(_borrowLtv(others[i], escrow), 3500);
            assertEq(_liqLtv(others[i], escrow), 3750);
        }
        (uint16 capAfter,) = escrow.caps();
        assertEq(capAfter, capBefore);
        IPoppieRiskSteward.AssetInfo memory info = steward.assetInfo(token);
        assertEq(uint8(info.riskClass), uint8(BC));
        assertEq(info.bandHub, address(0));
    }

    function test_promoteAlreadyBlueChipAndUnknown() public {
        (address token,) = _listNew(BC, prime);
        vm.startPrank(loosener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.AlreadyPromoted.selector, token));
        steward.promote(token);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownAsset.selector, address(1)));
        steward.promote(address(1));
        vm.stopPrank();
    }

    function test_promoteIsAllOrNothing() public {
        (address token, IEVault escrow) = _listNew(M1, hubM1);
        // Break one hub: the steward can no longer govern it.
        vm.prank(address(governor));
        hubM3.setGovernorAdmin(address(0xdead));

        vm.prank(loosener);
        vm.expectRevert();
        steward.promote(token);

        assertEq(_liqLtv(prime, escrow), 0);
        assertEq(_liqLtv(hubM2, escrow), 0);
        assertEq(uint8(steward.assetInfo(token).riskClass), uint8(M1));
    }

    // -- demote ---------------------------------------------------------------------------------

    function test_demoteLeavingHubsAndBandHub() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        _forceAll(escrow, 7000, 7500);

        vm.expectEmit(address(steward));
        emit IPoppieRiskSteward.Demoted(token, M1);
        vm.prank(tightener);
        steward.demote(token, M1, address(hubM1));

        // Leaving hubs: borrow 0 at once, liquidation ramps 75 -> 0 over 7500/500 days = 15 days.
        IEVault[3] memory leaving = [prime, hubM2, hubM3];
        for (uint256 i; i < 3; ++i) {
            assertEq(_borrowLtv(leaving[i], escrow), 0);
            (uint16 target, uint48 end) = _liqTarget(leaving[i], escrow);
            assertEq(target, 0);
            assertEq(end, START + 15 days);
            assertEq(_liqLtv(leaving[i], escrow), 7500);
        }
        // Band hub: borrow to 50 at once, liquidation 75 -> 58 over 1700/500 days = 3.4 days (> 72h).
        assertEq(_borrowLtv(hubM1, escrow), 5000);
        (uint16 t1, uint48 e1) = _liqTarget(hubM1, escrow);
        assertEq(t1, 5800);
        assertEq(e1, START + 293_760);

        IPoppieRiskSteward.AssetInfo memory info = steward.assetInfo(token);
        assertEq(uint8(info.riskClass), uint8(M1));
        assertEq(info.bandHub, address(hubM1));
    }

    function test_demoteRampExactProRataAndBandFloor() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        _forceAll(escrow, 300, 5900); // band-hub cut 100 -> 17,280s, floored to 72h; leaving cut 5900
        vm.prank(tightener);
        steward.demote(token, M1, address(hubM1));
        (, uint48 eBand) = _liqTarget(hubM1, escrow);
        assertEq(eBand, START + H72);
        (, uint48 eLeave) = _liqTarget(prime, escrow);
        assertEq(eLeave, START + 1_019_520); // 5900 * 86400 / 500

        (address t2, IEVault e2) = _listNew(BC, prime);
        _forceAll(e2, 0, 3);
        vm.prank(tightener);
        steward.demote(t2, M2, address(hubM2));
        (, uint48 eSmall) = _liqTarget(prime, e2);
        assertEq(eSmall, START + 519); // ceil(3 * 86400 / 500) = ceil(518.4); no 72h floor when leaving
    }

    function test_demoteChecks() public {
        (address bc,) = _listNew(BC, prime);
        (address lt,) = _listNew(M1, hubM1);
        vm.startPrank(tightener);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotBlueChip.selector, lt));
        steward.demote(lt, M2, address(hubM2));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.WrongBand.selector, address(hubM2), M1));
        steward.demote(bc, M1, address(hubM2));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownHub.selector, address(2)));
        steward.demote(bc, M1, address(2));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.NotALowering.selector, address(prime), bc));
        steward.demote(bc, BC, address(prime));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.UnknownAsset.selector, address(1)));
        steward.demote(address(1), M1, address(hubM1));
        vm.stopPrank();
    }

    function test_demoteRateLimitThreePerRolling7Days() public {
        address[5] memory t;
        for (uint256 i; i < 5; ++i) {
            (t[i],) = _listNew(BC, prime);
        }
        vm.startPrank(tightener);
        steward.demote(t[0], M1, address(hubM1));
        vm.warp(START + 1 days);
        steward.demote(t[1], M1, address(hubM1));
        vm.warp(START + 2 days);
        steward.demote(t[2], M1, address(hubM1));

        vm.warp(START + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.DemoteRateLimited.selector, uint40(START + 7 days)));
        steward.demote(t[3], M1, address(hubM1));
        vm.warp(START + 7 days);
        steward.demote(t[3], M1, address(hubM1));
        vm.expectRevert(abi.encodeWithSelector(IPoppieRiskSteward.DemoteRateLimited.selector, uint40(START + 8 days)));
        steward.demote(t[4], M1, address(hubM1));
        vm.stopPrank();
    }

    function test_cancelDemotionRampNeverAboveNewClassCeiling() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        _forceAll(escrow, 7000, 7500);
        vm.prank(tightener);
        steward.demote(token, M1, address(hubM1));
        vm.warp(START + 1 days);

        vm.prank(ops);
        steward.cancelRamp(_rampRef(prime, token));
        (uint16 target,) = _liqTarget(prime, escrow);
        assertEq(target, 5800);
        assertLe(_liqLtv(prime, escrow), 7500);
        assertEq(_borrowLtv(prime, escrow), 0);
        vm.warp(START + 30 days);
        assertEq(_liqLtv(prime, escrow), 5800);
    }

    function test_promoteAfterDemotionDuringRampNeverCutsInstantly() public {
        (address token, IEVault escrow) = _listNew(BC, prime);
        _forceAll(escrow, 7000, 7500);
        vm.prank(tightener);
        steward.demote(token, M1, address(hubM1));
        vm.warp(START + 1 days);
        uint16 before = _liqLtv(prime, escrow);
        vm.prank(loosener);
        steward.promote(token);
        assertEq(_liqLtv(prime, escrow), before);
        (uint16 target,) = _liqTarget(prime, escrow);
        assertEq(target, 3750);
    }
}
