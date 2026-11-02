// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {Errors as EVKErrors} from "evk/EVault/shared/Errors.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {IPoppieEscrowHook} from "../../src/interfaces/IPoppieEscrowHook.sol";
import {IPoppieHubHook} from "../../src/interfaces/IPoppieHubHook.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {FullStackFixture} from "../harness/FullStackFixture.sol";

/// @notice Price states through the whole stack (ARCHITECTURE.md "Price states and closed markets"): liquidations by
/// state, the haircut bid for borrow and withdraw while Closed, deposit blocking, deposit and borrow pauses, and the
/// operations that are never blocked.
contract PriceStatesIntegrationTest is FullStackFixture {
    address internal borrower = makeAddr("borrower");
    IEVault internal escrow;

    function setUp() public override {
        super.setUp();
        escrow = _listAsset(address(stock), false, IPoppieRiskSteward.RiskClass.BlueChip, prime, 200e18);
        _depositCollateral(address(stock), borrower, 10e18, prime);
    }

    /// @dev Borrow 699 against 10 stock at 200 (35% -> 700 of borrowing power), then drop to 185: liquidatable at
    /// the mid (10 * 185 * 37.5% = 693.75 < 699).
    function _underwater() internal {
        _borrow(prime, borrower, 699e6);
        _push(address(stock), 185e18);
    }

    function _pauseAsset() internal {
        address[] memory a = new address[](1);
        a[0] = address(stock);
        vm.prank(keeper);
        oracle.pauseAssets(a);
    }

    function _liquidateExpectRevert(bytes4 selector) internal {
        vm.startPrank(liquidator);
        evc.enableController(liquidator, address(prime));
        vm.expectRevert(selector);
        prime.liquidate(borrower, address(escrow), type(uint256).max, 0);
        vm.stopPrank();
    }

    // -- Liquidation by state -------------------------------------------------------------------

    function test_liquidationSucceedsWhileLive() public {
        _underwater();
        assertEq(uint8(_state(address(stock))), uint8(IPoppieEulerOracle.PriceState.Live));
        _liquidate(prime, borrower, escrow);
        assertGt(escrow.balanceOf(liquidator), 0);
    }

    function test_liquidationRevertsWhileClosedByStaleness() public {
        _underwater();
        vm.warp(block.timestamp + oracle.maxPriceAge() + 1);
        assertEq(uint8(_state(address(stock))), uint8(IPoppieEulerOracle.PriceState.Closed));
        _liquidateExpectRevert(IPoppieEulerAdapter.PriceUnavailable.selector);
    }

    function test_liquidationRevertsWhileClosedByPause() public {
        _underwater();
        _pauseAsset();
        _liquidateExpectRevert(IPoppieEulerAdapter.PriceUnavailable.selector);
    }

    function test_liquidationRevertsWhileUnconfirmedThenSucceedsOnConfirm() public {
        _borrow(prime, borrower, 699e6);
        _push(address(stock), 150e18); // -25%: beyond the 10% blue-chip bound
        assertEq(uint8(_state(address(stock))), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        _liquidateExpectRevert(IPoppieEulerAdapter.PriceUnconfirmed.selector);
        vm.prank(liquidator);
        evc.disableController(liquidator);

        _confirm(address(stock), 150e18);
        _liquidate(prime, borrower, escrow);
        assertGt(escrow.balanceOf(liquidator), 0);
    }

    // -- Closed: haircut bid for borrow and withdraw --------------------------------------------

    function test_borrowWhileClosedUsesHaircutBid() public {
        _pauseAsset();
        // Bid = 200 * (1 - 10%) = 180 -> 10 * 180 * 35% = 630.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(prime, borrower, 630e6, address(feeRouter));
        items[1] = _forwardItem(prime, borrower, borrower);
        vm.prank(borrower);
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        evc.batch(items);
        _borrow(prime, borrower, 629e6);
    }

    function test_withdrawWhileClosedUsesHaircutBid() public {
        _borrow(prime, borrower, 315e6);
        _pauseAsset();
        // Need 315 / (180 * 35%) = 5 stock left: withdrawing 5 leaves exactly 5 -> fails (not strictly above);
        // 4.99 passes.
        vm.startPrank(borrower);
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        escrow.withdraw(5e18, borrower, borrower);
        escrow.withdraw(4.99e18, borrower, borrower);
        vm.stopPrank();
    }

    // -- Deposits -------------------------------------------------------------------------------

    function test_depositBlockedWhileClosedAllowedWhileUnconfirmed() public {
        stock.mint(borrower, 1e18);
        vm.prank(borrower);
        stock.approve(address(escrow), type(uint256).max);

        _pauseAsset();
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEscrowHook.AssetClosed.selector, address(escrow), address(stock)));
        escrow.deposit(1e18, borrower);

        vm.prank(ops);
        address[] memory a = new address[](1);
        a[0] = address(stock);
        oracle.unpauseAssets(a);
        _push(address(stock), 150e18); // Unconfirmed
        vm.prank(borrower);
        escrow.deposit(1e18, borrower);
    }

    function test_collateralSeizedDuringDepositPause() public {
        _underwater();
        address[] memory v = new address[](1);
        v[0] = address(escrow);
        vm.prank(guard);
        escrowHook.pauseDeposits(v, 24 hours);

        _liquidate(prime, borrower, escrow);
        assertGt(escrow.balanceOf(liquidator), 0);

        // An ordinary transfer is still blocked.
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEscrowHook.DepositsArePaused.selector, address(escrow), uint40(T0 + 24 hours))
        );
        escrow.transfer(makeAddr("x"), 1);
    }

    function test_guardRepausesImmediatelyAfterExpiry() public {
        address[] memory v = new address[](1);
        v[0] = address(escrow);
        address[] memory h = new address[](1);
        h[0] = address(prime);
        vm.startPrank(guard);
        escrowHook.pauseDeposits(v, 24 hours);
        hubHook.pauseBorrows(h, 24 hours);
        vm.warp(T0 + 24 hours);
        escrowHook.pauseDeposits(v, 24 hours);
        hubHook.pauseBorrows(h, 24 hours);
        vm.stopPrank();
        _refresh();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(prime, borrower, 1e6, address(feeRouter));
        items[1] = _forwardItem(prime, borrower, borrower);
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieHubHook.BorrowsArePaused.selector, address(prime), uint40(T0 + 48 hours))
        );
        evc.batch(items);
    }

    // -- Never blocked --------------------------------------------------------------------------

    function test_repayAndWithdrawNeverBlocked() public {
        _borrow(prime, borrower, 300e6);

        // Everything at once: asset Closed, deposits paused, borrows paused, liquidations paused.
        _pauseAsset();
        address[] memory v = new address[](1);
        v[0] = address(escrow);
        address[] memory h = new address[](1);
        h[0] = address(prime);
        vm.startPrank(guard);
        escrowHook.pauseDeposits(v, 24 hours);
        hubHook.pauseBorrows(h, 24 hours);
        vm.stopPrank();
        vm.prank(ops);
        hubHook.pauseLiquidations(h, 6 hours);

        usdc.mint(borrower, 10e6);
        vm.startPrank(borrower);
        usdc.approve(address(prime), type(uint256).max);
        prime.repay(type(uint256).max, borrower);
        evc.disableController(borrower);
        escrow.withdraw(10e18, borrower, borrower);
        vm.stopPrank();
        assertEq(stock.balanceOf(borrower), 10e18);

        // Lender withdraws from the hub too.
        vm.prank(lender);
        prime.withdraw(1_000e6, lender, lender);
    }
}
