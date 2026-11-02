// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {Errors as EVKErrors} from "evk/EVault/shared/Errors.sol";

import {IPoppieHubHook} from "../../src/interfaces/IPoppieHubHook.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {FullStackFixture} from "../harness/FullStackFixture.sol";

/// @notice V2_PLAN section 8 end-to-end: the origination fee path, the blocked borrow routes, and the vault status
/// check on every other operation. All contracts real.
contract FeeAndBorrowIntegrationTest is FullStackFixture {
    address internal borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();
        _listAsset(address(stock), false, IPoppieRiskSteward.RiskClass.BlueChip, prime, 200e18);
        // 10 stock = 2,000 USD; blue-chip launch borrow LTV 35% -> 700 USD of borrowing power.
        _depositCollateral(address(stock), borrower, 10e18, prime);
    }

    function test_wiringSmoke() public view {
        assertEq(prime.LTVBorrow(address(escrowOf[address(stock)])), 3500);
        assertEq(hubM3.LTVBorrow(address(escrowOf[address(stock)])), 3500);
        // Router resolves escrow -> token -> adapter.
        assertEq(router.getQuote(1e18, address(escrowOf[address(stock)]), USD), 200e18);
        assertEq(router.getQuote(1e6, address(usdc), USD), 1e18);
    }

    function test_batchedBorrowAndForwardFeeToHubFeeReceiver() public {
        _borrow(prime, borrower, 500e6);
        uint256 fee = uint256(500e6) * FEE_BPS / 10_000; // exact here; the router rounds the fee up
        assertEq(usdc.balanceOf(prime.feeReceiver()), fee);
        assertEq(prime.feeReceiver(), feeReceiver);
        assertEq(usdc.balanceOf(borrower), 500e6 - fee);
        assertEq(prime.debtOf(borrower), 500e6);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    function test_borrowBeyondBidLtvReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        // EVK requires collateral value strictly above the liability: exactly 700 fails, 699.99 passes.
        items[0] = _borrowItem(prime, borrower, 700e6, address(feeRouter));
        items[1] = _forwardItem(prime, borrower, borrower);
        vm.prank(borrower);
        vm.expectRevert(EVKErrors.E_AccountLiquidity.selector);
        evc.batch(items);
        _borrow(prime, borrower, 699.99e6);
    }

    function test_directBorrowReverts() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.ReceiverNotFeeRouter.selector, borrower));
        prime.borrow(100e6, borrower);
    }

    function test_borrowWithoutForwardReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = _borrowItem(prime, borrower, 100e6, address(feeRouter));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.PendingNotForwarded.selector, address(prime), 100e6));
        evc.batch(items);
    }

    function test_maxBorrowReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(prime, borrower, type(uint256).max, address(feeRouter));
        items[1] = _forwardItem(prime, borrower, borrower);
        vm.prank(borrower);
        vm.expectRevert(IPoppieHubHook.MaxBorrowNotAllowed.selector);
        evc.batch(items);
    }

    function test_flashLoanReverts() public {
        vm.prank(borrower);
        vm.expectRevert(IPoppieHubHook.FlashLoansDisabled.selector);
        prime.flashLoan(1e6, "");
    }

    function test_statusCheckPassesOnRepayDepositWithdraw() public {
        _borrow(prime, borrower, 500e6);
        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(prime), type(uint256).max);
        prime.repay(200e6, borrower);
        prime.deposit(100e6, borrower);
        prime.withdraw(50e6, borrower, borrower);
        prime.repay(type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(prime.debtOf(borrower), 0);
    }

    function test_statusCheckPassesOnLiquidate() public {
        _borrow(prime, borrower, 699e6);
        // 200 -> 190: inside the 10% blue-chip bound, stays Live; 10 * 190 * 37.5% = 712.5 > 700, healthy.
        // 200 -> 185: 693.75 < 699, liquidatable.
        _push(address(stock), 185e18);
        assertEq(uint8(_state(address(stock))), 2); // Live
        _liquidate(prime, borrower, escrowOf[address(stock)]);
        assertLt(prime.debtOf(borrower), 699e6);
        assertGt(escrowOf[address(stock)].balanceOf(liquidator), 0);
    }

    function test_feeAppliesPerHub() public {
        IEVault escrow = escrowOf[address(stock)];
        vm.prank(borrower);
        evc.disableCollateral(borrower, address(escrow));
        address b2 = makeAddr("b2");
        _depositCollateral(address(stock), b2, 10e18, hubM2);
        vm.prank(ops);
        feeRouter.setFeeBps(address(hubM2), 100);
        _borrow(hubM2, b2, 100e6);
        assertEq(usdc.balanceOf(feeReceiver), 1e6);
    }
}
