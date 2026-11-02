// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault, IGovernance} from "evk/EVault/IEVault.sol";

import {PoppieRiskSteward} from "../../src/steward/PoppieRiskSteward.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";
import {MS_OPS, K_TIGHTEN, K_LOOSEN} from "../../src/access/Roles.sol";

import {PoppieTestBase} from "./PoppieTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Exposes the steward's internal AmountCap encoder for tests.
contract StewardHarness is PoppieRiskSteward {
    constructor(address initialAdmin, address governor_) PoppieRiskSteward(initialAdmin, governor_) {}

    function encodeCapDown(uint256 amount) external pure returns (uint16) {
        return _encodeCapDown(amount);
    }
}

/// @notice Local EVK stack with the real `PoppieRiskSteward` governing four hubs (Prime, M1, M2, M3) through the
/// Euler `GovernorAccessControl`. Escrow vaults are created per test with `_newEscrow` and listed with `_list`.
/// No oracle is needed: `setLTV` and `setCaps` do not price anything.
abstract contract StewardFixture is PoppieTestBase {
    StewardHarness internal steward;

    IEVault internal prime;
    IEVault internal hubM1;
    IEVault internal hubM2;
    IEVault internal hubM3;

    address internal ops = makeAddr("ops");
    address internal tightener = makeAddr("tightener");
    address internal loosener = makeAddr("loosener");

    /// @dev Raw AmountCap ceilings used by default: 1,000,000 tokens (18 decimals) for escrows,
    /// 100,000,000 USDC supply / 50,000,000 USDC borrow for hubs.
    uint16 internal escrowSupplyCeiling;
    uint16 internal hubSupplyCeiling;
    uint16 internal hubBorrowCeiling;

    uint256 internal constant START = 1_000_000;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(START);

        steward = new StewardHarness(admin, address(governor));
        escrowSupplyCeiling = steward.encodeCapDown(1_000_000e18);
        hubSupplyCeiling = steward.encodeCapDown(100_000_000e6);
        hubBorrowCeiling = steward.encodeCapDown(50_000_000e6);

        vm.startPrank(admin);
        governor.grantRole(bytes32(IGovernance.setLTV.selector), address(steward));
        governor.grantRole(bytes32(IGovernance.setCaps.selector), address(steward));
        steward.grantRole(MS_OPS, ops);
        steward.grantRole(K_TIGHTEN, tightener);
        steward.grantRole(K_LOOSEN, loosener);
        vm.stopPrank();

        prime = _newHub(IPoppieRiskSteward.RiskClass.BlueChip);
        hubM1 = _newHub(IPoppieRiskSteward.RiskClass.M1);
        hubM2 = _newHub(IPoppieRiskSteward.RiskClass.M2);
        hubM3 = _newHub(IPoppieRiskSteward.RiskClass.M3);
    }

    function _newHub(IPoppieRiskSteward.RiskClass band) internal returns (IEVault h) {
        h = _createHub();
        // Finite hub caps (half the ceilings) so the cap functions can move them either way.
        h.setCaps(steward.encodeCapDown(50_000_000e6), steward.encodeCapDown(25_000_000e6));
        h.setGovernorAdmin(address(governor));
        vm.prank(admin);
        steward.addHub(address(h), band);
        IPoppieRiskSteward.CapCeilingChange[] memory c = new IPoppieRiskSteward.CapCeilingChange[](1);
        c[0] = IPoppieRiskSteward.CapCeilingChange(address(h), hubSupplyCeiling, hubBorrowCeiling);
        vm.prank(ops);
        steward.setCapCeiling(c);
    }

    /// @dev A fresh token and its escrow vault (governed by `governor`), with the default cap ceiling set.
    function _newEscrow() internal returns (address token, IEVault escrow) {
        token = address(new MockERC20("Stock", "STK", 18));
        escrow = _createEscrow(token);
        escrow.setGovernorAdmin(address(governor));
        _setCeiling(address(escrow), escrowSupplyCeiling, 1);
    }

    function _setCeiling(address vault, uint16 supply, uint16 borrow) internal {
        IPoppieRiskSteward.CapCeilingChange[] memory c = new IPoppieRiskSteward.CapCeilingChange[](1);
        c[0] = IPoppieRiskSteward.CapCeilingChange(vault, supply, borrow);
        vm.prank(ops);
        steward.setCapCeiling(c);
    }

    /// @dev Create, ceiling and list an asset of `riskClass` in `hub`.
    function _listNew(IPoppieRiskSteward.RiskClass riskClass, IEVault hub)
        internal
        returns (address token, IEVault escrow)
    {
        (token, escrow) = _newEscrow();
        _list(token, address(escrow), address(hub), riskClass);
    }

    function _list(address token, address escrow, address hub, IPoppieRiskSteward.RiskClass riskClass) internal {
        IPoppieRiskSteward.Listing[] memory l = new IPoppieRiskSteward.Listing[](1);
        l[0] = IPoppieRiskSteward.Listing(token, escrow, hub, riskClass);
        vm.prank(ops);
        steward.list(l);
    }

    // -- Single-entry array builders ------------------------------------------------------------

    function _borrowChange(IEVault hub, address asset, uint16 ltv)
        internal
        pure
        returns (IPoppieRiskSteward.BorrowLtvChange[] memory c)
    {
        c = new IPoppieRiskSteward.BorrowLtvChange[](1);
        c[0] = IPoppieRiskSteward.BorrowLtvChange(address(hub), asset, ltv);
    }

    function _liqChange(IEVault hub, address asset, uint16 ltv, uint32 ramp)
        internal
        pure
        returns (IPoppieRiskSteward.LiquidationLtvChange[] memory c)
    {
        c = new IPoppieRiskSteward.LiquidationLtvChange[](1);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(address(hub), asset, ltv, ramp);
    }

    function _raise(IEVault hub, address asset, uint16 borrowLtv, uint16 liqLtv)
        internal
        pure
        returns (IPoppieRiskSteward.LtvRaise[] memory c)
    {
        c = new IPoppieRiskSteward.LtvRaise[](1);
        c[0] = IPoppieRiskSteward.LtvRaise(address(hub), asset, borrowLtv, liqLtv);
    }

    function _caps(address vault, uint16 supply, uint16 borrow)
        internal
        pure
        returns (IPoppieRiskSteward.CapChange[] memory c)
    {
        c = new IPoppieRiskSteward.CapChange[](1);
        c[0] = IPoppieRiskSteward.CapChange(vault, supply, borrow);
    }

    function _rampRef(IEVault hub, address asset) internal pure returns (IPoppieRiskSteward.RampRef[] memory r) {
        r = new IPoppieRiskSteward.RampRef[](1);
        r[0] = IPoppieRiskSteward.RampRef(address(hub), asset);
    }

    // -- Readers --------------------------------------------------------------------------------

    function _borrowLtv(IEVault hub, IEVault escrow) internal view returns (uint16) {
        return hub.LTVBorrow(address(escrow));
    }

    function _liqLtv(IEVault hub, IEVault escrow) internal view returns (uint16) {
        return hub.LTVLiquidation(address(escrow));
    }

    /// @dev Converged liquidation LTV target and ramp end.
    function _liqTarget(IEVault hub, IEVault escrow) internal view returns (uint16 target, uint48 end) {
        (, target,, end,) = hub.LTVFull(address(escrow));
    }

    function _allHubs() internal view returns (IEVault[4] memory) {
        return [prime, hubM1, hubM2, hubM3];
    }
}
