// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {IPoppieBalanceWrapper} from "../../src/interfaces/IPoppieBalanceWrapper.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {FullStackFixture} from "../harness/FullStackFixture.sol";

/// @notice Pricing through escrow -> wrapper -> token -> adapter, with a balance-changing token (splits and in-kind
/// dividends) and a distributing token (stablecoin dividends swept to the reserve).
contract WrapperPricingIntegrationTest is FullStackFixture {
    address internal borrower = makeAddr("borrower");
    IEVault internal rbEscrow;
    IEVault internal divEscrow;
    PoppieBalanceWrapper internal rbWrapper;
    PoppieBalanceWrapper internal divWrapper;

    function setUp() public override {
        super.setUp();
        rbEscrow = _listAsset(address(rebasing), true, IPoppieRiskSteward.RiskClass.M2, hubM2, 100e18);
        divEscrow = _listAsset(address(dividend), true, IPoppieRiskSteward.RiskClass.M1, hubM1, 50e18);
        rbWrapper = PoppieBalanceWrapper(heldBy[address(rebasing)]);
        divWrapper = PoppieBalanceWrapper(heldBy[address(dividend)]);
    }

    function _value(IEVault escrow, address who) internal view returns (uint256) {
        return router.getQuote(escrow.balanceOf(who), address(escrow), USD);
    }

    function test_listingTookTheWrapperPath() public view {
        assertEq(steward.assetInfo(address(rebasing)).wrapper, address(rbWrapper));
        assertEq(rbEscrow.asset(), address(rbWrapper));
        assertEq(router.resolvedVaults(address(rbEscrow)), address(rbWrapper));
        assertEq(router.resolvedVaults(address(rbWrapper)), address(rebasing));
        assertEq(divEscrow.asset(), address(divWrapper));
    }

    function test_priceThroughEscrowWrapperToken() public {
        _depositCollateral(address(rebasing), borrower, 10e18, hubM2);
        assertApproxEqAbs(_value(rbEscrow, borrower), 1_000e18, 1e9);
        // Launch LTV M2 22.5% of 1,000 -> 225 USDC of borrowing power.
        _borrow(hubM2, borrower, 224e6);
    }

    /// @dev The correct split sequence: the keeper pushes the post-split price as the split lands. The new price
    /// is beyond the class bound, so it is Unconfirmed and the bid is min(P, L(1-h)) = P: no overvaluation.
    function test_splitWithSyncedPriceKeepsValue() public {
        _depositCollateral(address(rebasing), borrower, 10e18, hubM2);
        uint256 before = _value(rbEscrow, borrower);

        rebasing.rebase(2e18); // 2-for-1
        _push(address(rebasing), 50e18);
        assertEq(uint8(oracle.state(address(rebasing))), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        (uint256 bid,) = router.getQuotes(rbEscrow.balanceOf(borrower), address(rbEscrow), USD);
        assertApproxEqRel(bid, before, 1e15);

        _confirm(address(rebasing), 50e18);
        assertApproxEqRel(_value(rbEscrow, borrower), before, 1e15);
    }

    function test_reverseSplitWithSyncedPriceKeepsValue() public {
        _depositCollateral(address(rebasing), borrower, 10e18, hubM2);
        uint256 before = _value(rbEscrow, borrower);
        rebasing.rebase(0.5e18); // 1-for-2
        _push(address(rebasing), 200e18);
        // Upward move: bid stays at L(1-h) on the stale per-share price -> undervalued (safe side) until confirmed.
        (uint256 bid,) = router.getQuotes(rbEscrow.balanceOf(borrower), address(rbEscrow), USD);
        assertLt(bid, before);
        _confirm(address(rebasing), 200e18);
        assertApproxEqRel(_value(rbEscrow, borrower), before, 1e15);
    }

    /// @dev Finding (operational, documented for the corporate-action runbook): if a split lands while the asset is
    /// Closed on its pre-split price and the keeper has not pushed the new price, the bid is L(1-h) on a doubled
    /// balance, overvaluing collateral by 2 x (1 - h). Mitigation is procedural: push the post-split price at the
    /// split (Unconfirmed, safe), and/or K_TIGHTEN lowers the borrow LTV before the corporate action.
    function test_finding_splitWhileClosedOnStalePriceOvervaluesBid() public {
        _depositCollateral(address(rebasing), borrower, 10e18, hubM2);
        uint256 before = _value(rbEscrow, borrower);
        address[] memory a = new address[](1);
        a[0] = address(rebasing);
        vm.prank(keeper);
        oracle.pauseAssets(a);
        rebasing.rebase(2e18);
        (uint256 bid,) = router.getQuotes(rbEscrow.balanceOf(borrower), address(rbEscrow), USD);
        // 2 x (1 - 20%) = 1.6x the true value.
        assertApproxEqRel(bid, before * 16 / 10, 1e15);
    }

    function test_inKindDividendRebaseRaisesValueProRata() public {
        _depositCollateral(address(rebasing), borrower, 10e18, hubM2);
        uint256 before = _value(rbEscrow, borrower);
        uint256 escrowShares = rbEscrow.balanceOf(borrower);
        uint256 wrapperShares = rbWrapper.totalSupply();
        rebasing.rebaseBy(101, 100);
        assertApproxEqRel(_value(rbEscrow, borrower), before * 101 / 100, 1e15);
        // Share counts did not move; only the wrapper's balance per share did.
        assertEq(rbEscrow.balanceOf(borrower), escrowShares);
        assertEq(rbWrapper.totalSupply(), wrapperShares);
    }

    function test_dividendSweptToReserveNeverUnderlying() public {
        _depositCollateral(address(dividend), borrower, 100e18, hubM1);
        uint256 before = _value(divEscrow, borrower);
        uint256 underlyingBefore = dividend.balanceOf(address(divWrapper));

        address[] memory holders = new address[](1);
        holders[0] = address(divWrapper);
        dividend.payDividend(holders, 0.5e6); // 0.50 USDC per token
        uint256 paid = usdc.balanceOf(address(divWrapper));
        assertGt(paid, 0);

        uint256 reserveBefore = usdc.balanceOf(reserve);
        vm.prank(makeAddr("anyone")); // permissionless
        divWrapper.sweep(address(usdc));
        assertEq(usdc.balanceOf(reserve) - reserveBefore, paid);
        assertEq(usdc.balanceOf(address(divWrapper)), 0);
        assertEq(dividend.balanceOf(address(divWrapper)), underlyingBefore);
        assertEq(_value(divEscrow, borrower), before);

        vm.expectRevert(IPoppieBalanceWrapper.CannotSweepUnderlying.selector);
        divWrapper.sweep(address(dividend));
    }

    function test_borrowAgainstWrappedCollateralEndToEnd() public {
        _depositCollateral(address(dividend), borrower, 100e18, hubM1);
        // 100 * 50 = 5,000 USD; M1 launch borrow LTV 25% -> 1,250.
        _borrow(hubM1, borrower, 1_249e6);
        assertEq(hubM1.debtOf(borrower), 1_249e6);
        // Repay and unwind to the underlying token.
        usdc.mint(borrower, 10e6);
        vm.startPrank(borrower);
        usdc.approve(address(hubM1), type(uint256).max);
        hubM1.repay(type(uint256).max, borrower);
        divEscrow.redeem(divEscrow.balanceOf(borrower), borrower, borrower);
        divWrapper.redeem(divWrapper.balanceOf(borrower), borrower, borrower);
        vm.stopPrank();
        assertApproxEqAbs(IERC20(address(dividend)).balanceOf(borrower), 100e18, 1);
    }
}
