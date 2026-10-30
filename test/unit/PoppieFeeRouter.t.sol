// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PoppieFeeRouter} from "../../src/fee/PoppieFeeRouter.sol";
import {IPoppieFeeRouter} from "../../src/interfaces/IPoppieFeeRouter.sol";
import {IPoppieHubHook} from "../../src/interfaces/IPoppieHubHook.sol";
import {MS_OPS} from "../../src/access/Roles.sol";

import {HubHookFixture} from "../harness/HubHookFixture.sol";

/// @notice The fee router and hub hook against a real EVK hub. This is the status-check prototype of the build
/// order (V2_PLAN.md section 9): it pins how EVK drives the hook (borrow hook, deferred vault status check at the
/// end of an EVC batch or call) and that the batched borrow + forward flow, direct-borrow revert and
/// no-pending status checks behave as CONTRACT_SPEC.md sections 3.3 and 3.4 assume.
contract PoppieFeeRouterTest is HubHookFixture {
    bytes4 internal constant ERR_PENDING_NOT_FORWARDED = bytes4(keccak256("PendingNotForwarded(address,uint256)"));

    // -- Flow: batched borrow + forward ---------------------------------------------------------

    function test_batchedBorrowForwardSucceeds() public {
        uint256 amount = 800e6;
        uint256 fee = 2e6; // 25 bps

        vm.expectEmit(true, true, true, true, address(feeRouter));
        emit IPoppieFeeRouter.PendingRecorded(address(hub), borrower, amount);
        vm.expectEmit(true, true, true, true, address(feeRouter));
        emit IPoppieFeeRouter.Forwarded(address(hub), borrower, recipient, fee, amount - fee, feeReceiver);
        _borrowAndForward(borrower, amount, recipient);

        assertEq(usdc.balanceOf(feeReceiver), fee, "fee at hub.feeReceiver()");
        assertEq(usdc.balanceOf(recipient), amount - fee, "net to the chosen receiver");
        assertEq(usdc.balanceOf(address(feeRouter)), 0, "router holds nothing");
        assertEq(hub.debtOf(borrower), amount, "debt is the gross amount");
        assertEq(feeRouter.pendingTotal(address(hub)), 0);
        assertEq(feeRouter.pending(address(hub), borrower), 0);
    }

    function test_batchedBorrowForwardToSelfLeavesNetWithBorrower() public {
        _borrowAndForward(borrower, 400e6, borrower);
        assertEq(usdc.balanceOf(borrower), 400e6 - 1e6);
        assertEq(usdc.balanceOf(feeReceiver), 1e6);
    }

    function test_batchedBorrowFromSubAccountForwardsToAnyone() public {
        address sub = _sub(borrower, 3);
        stock.mint(borrower, 10e18);
        vm.startPrank(borrower);
        stock.approve(address(escrow), 10e18);
        escrow.deposit(10e18, sub);
        evc.enableCollateral(sub, address(escrow));
        evc.enableController(sub, address(hub));
        vm.stopPrank();
        // The owner acts for the sub-account.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hub, sub, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), sub, recipient);
        _batch(borrower, items);
        assertEq(usdc.balanceOf(recipient), 100e6 - 0.25e6);
        assertEq(hub.debtOf(sub), 100e6);
    }

    function test_twoBorrowsInOneBatchForwardedTwice() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](4);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, recipient);
        items[2] = _borrowItem(hub, borrower, 200e6, address(feeRouter));
        items[3] = _forwardItem(address(hub), borrower, recipient);
        _batch(borrower, items);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
        assertEq(hub.debtOf(borrower), 300e6);
        assertEq(usdc.balanceOf(feeReceiver), 0.25e6 + 0.5e6);
    }

    function test_twoBorrowsOneForwardCoversBothPending() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _borrowItem(hub, borrower, 200e6, address(feeRouter));
        items[2] = _forwardItem(address(hub), borrower, recipient);
        _batch(borrower, items);
        assertEq(usdc.balanceOf(feeReceiver), 0.75e6);
        assertEq(usdc.balanceOf(recipient), 300e6 - 0.75e6);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    // -- Direct and malformed borrows revert ----------------------------------------------------

    function test_directBorrowReverts() public {
        // Direct borrow to the router: the status check at the end of the call finds pending funds.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ERR_PENDING_NOT_FORWARDED, address(hub), 100e6));
        hub.borrow(100e6, address(feeRouter));
    }

    function test_directBorrowToSelfRevertsReceiverNotFeeRouter() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.ReceiverNotFeeRouter.selector, borrower));
        hub.borrow(100e6, borrower);
    }

    function test_batchedBorrowToSelfReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = _borrowItem(hub, borrower, 100e6, borrower);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.ReceiverNotFeeRouter.selector, borrower));
        evc.batch(items);
    }

    function test_batchedBorrowWithoutForwardReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ERR_PENDING_NOT_FORWARDED, address(hub), 100e6));
        evc.batch(items);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    function test_forwardBeforeBorrowReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _forwardItem(address(hub), borrower, recipient);
        items[1] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.NothingPending.selector, address(hub), borrower));
        evc.batch(items);
    }

    function test_borrowAfterForwardWithoutSecondForwardReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, recipient);
        items[2] = _borrowItem(hub, borrower, 50e6, address(feeRouter));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ERR_PENDING_NOT_FORWARDED, address(hub), 50e6));
        evc.batch(items);
    }

    function test_maxBorrowReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hub, borrower, type(uint256).max, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, recipient);
        vm.prank(borrower);
        vm.expectRevert(IPoppieHubHook.MaxBorrowNotAllowed.selector);
        evc.batch(items);
    }

    function test_flashLoanReverts() public {
        vm.prank(borrower);
        vm.expectRevert(IPoppieHubHook.FlashLoansDisabled.selector);
        hub.flashLoan(1e6, "");
    }

    function test_borrowAboveCollateralStillReverts() public {
        // 2,000 USD of stock at 50% LTV: 1,000 USDC of power; the fee flow does not change the account check.
        vm.expectRevert();
        _borrowAndForward(borrower, 1_100e6, recipient);
    }

    // -- Status check passes with nothing pending -----------------------------------------------

    function test_statusCheckPassesOnDeposit() public {
        usdc.mint(lender, 10e6);
        vm.prank(lender);
        hub.deposit(10e6, lender);
    }

    function test_statusCheckPassesOnRepayAndWithdraw() public {
        _openDebt(borrower, 500e6);

        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        usdc.approve(address(hub), type(uint256).max);
        hub.repay(100e6, borrower);
        hub.repay(type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(hub.debtOf(borrower), 0);

        vm.prank(lender);
        hub.withdraw(10e6, lender, lender);
    }

    function test_statusCheckPassesOnLiquidation() public {
        _openDebt(borrower, 900e6);

        // Price halves: 1,000 USD of collateral x 60% liquidation LTV < 900 USD of debt.
        adapter.setPrice(address(stock), 100e18);
        (uint256 maxRepay, uint256 maxYield) = hub.checkLiquidation(liquidator, borrower, address(escrow));
        assertGt(maxRepay, 0);
        assertGt(maxYield, 0);

        uint256 debtBefore = hub.debtOf(borrower);
        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
        assertLt(hub.debtOf(borrower), debtBefore);
        assertEq(feeRouter.pendingTotal(address(hub)), 0);
    }

    function test_statusCheckPassesOnRepayInsideBatchedBorrow() public {
        // Borrow + forward + repay in one batch: nothing pending at the end.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, borrower);
        items[2] = IEVC.BatchItem({
            targetContract: address(hub),
            onBehalfOfAccount: borrower,
            value: 0,
            data: abi.encodeCall(IBorrowing.repay, (50e6, borrower))
        });
        usdc.mint(borrower, 1e6);
        vm.prank(borrower);
        usdc.approve(address(hub), type(uint256).max);
        _batch(borrower, items);
        assertEq(hub.debtOf(borrower), 50e6);
    }

    // -- forward access -------------------------------------------------------------------------

    function test_forwardOutsideEVCReverts() public {
        vm.prank(borrower);
        vm.expectRevert(IPoppieFeeRouter.NotCalledViaEVC.selector);
        feeRouter.forward(address(hub), recipient);
    }

    function test_forwardForAnotherAccountReverts() public {
        // Borrow for the main account; try to forward it as a sub-account of the same owner.
        address other = _sub(borrower, 1);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), other, recipient);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.NothingPending.selector, address(hub), other));
        evc.batch(items);
    }

    function test_attackerCannotForwardVictimPending() public {
        // The attacker cannot act for the victim's account through the EVC, so its forward resolves its own
        // (empty) account.
        address attacker = makeAddr("attacker");
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = _forwardItem(address(hub), borrower, attacker);
        vm.prank(attacker);
        vm.expectRevert(); // EVC: not authorized for `borrower`
        evc.batch(items);

        items[0] = _forwardItem(address(hub), attacker, attacker);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.NothingPending.selector, address(hub), attacker));
        evc.batch(items);
    }

    function test_forwardToZeroOrRouterReverts() public {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, address(0));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.ZeroAddress.selector));
        evc.batch(items);

        items[1] = _forwardItem(address(hub), borrower, address(feeRouter));
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.ZeroAddress.selector));
        evc.batch(items);
    }

    // -- Registered hubs only -------------------------------------------------------------------

    function test_unregisteredVaultCannotUseHook() public {
        // A hub-like vault that points at the hook but was never registered: every hooked op reverts.
        IEVault rogue = _createHub();
        _configureHub(rogue);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, address(rogue)));
        rogue.flashLoan(1e6, "");

        address fresh = makeAddr("fresh");
        vm.prank(fresh);
        evc.enableController(fresh, address(rogue));
        vm.prank(fresh);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, address(rogue)));
        rogue.borrow(1e6, address(feeRouter));

        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, address(rogue)));
        vm.prank(address(rogue));
        hook.checkVaultStatus();
    }

    function test_hookEntryPointsRejectNonHubCallers() public {
        address nobody = makeAddr("nobody");
        vm.startPrank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, nobody));
        hook.borrow(1, address(feeRouter));
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, nobody));
        hook.liquidate(address(0), address(0), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, nobody));
        hook.flashLoan(0, "");
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.NotRegisteredHub.selector, nobody));
        hook.checkVaultStatus();
        vm.stopPrank();
    }

    function test_recordPendingOnlyHook() public {
        vm.prank(address(hub));
        vm.expectRevert(IPoppieFeeRouter.OnlyHook.selector);
        feeRouter.recordPending(address(hub), borrower, 1);

        vm.prank(borrower);
        vm.expectRevert(IPoppieFeeRouter.OnlyHook.selector);
        feeRouter.recordPending(address(hub), borrower, 1);
    }

    // -- Fee amount -----------------------------------------------------------------------------

    function test_feeRoundsUp() public {
        // 25 bps of 1,000,001 = 2,500.0025 -> 2,501.
        _borrowAndForward(borrower, 1_000_001, recipient);
        assertEq(usdc.balanceOf(feeReceiver), 2_501);
        assertEq(usdc.balanceOf(recipient), 1_000_001 - 2_501);
    }

    function test_feeOnTinyAmountRoundsToOneUnit() public {
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub), 1);
        _borrowAndForward(borrower, 1, recipient);
        assertEq(usdc.balanceOf(feeReceiver), 1);
        assertEq(usdc.balanceOf(recipient), 0);
    }

    function test_zeroFeeBpsSendsEverythingToRecipient() public {
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub), 0);
        _borrowAndForward(borrower, 100e6, recipient);
        assertEq(usdc.balanceOf(feeReceiver), 0);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_unsetFeeBpsMeansZeroFee() public {
        IEVault other = _createHub();
        _configureHub(other);
        vm.prank(admin);
        hook.registerHub(address(other));
        usdc.mint(lender, 10_000e6);
        vm.startPrank(lender);
        usdc.approve(address(other), type(uint256).max);
        other.deposit(10_000e6, lender);
        vm.stopPrank();
        other.setLTV(address(escrow), 0.5e4, 0.6e4, 0);

        address fresh = makeAddr("fresh");
        _depositCollateral(fresh, 10e18);
        vm.startPrank(fresh);
        evc.enableCollateral(fresh, address(escrow));
        evc.enableController(fresh, address(other));
        vm.stopPrank();

        _borrowAndForward(other, fresh, 100e6, recipient);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function testFuzz_feeIsCeilAndCapped(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 900e6);
        bps = uint16(bound(bps, 0, 100));
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub), bps);

        _borrowAndForward(borrower, amount, recipient);

        uint256 expected = (amount * bps + 9_999) / 10_000;
        assertEq(usdc.balanceOf(feeReceiver), expected);
        assertEq(usdc.balanceOf(recipient), amount - expected);
        assertLe(expected, amount * 100 / 10_000 + 1, "fee never above the cap, up to rounding");
        assertEq(usdc.balanceOf(address(feeRouter)), 0, "router balance unchanged");
    }

    // -- Fee receiver ---------------------------------------------------------------------------

    function test_feeLandsAtHubFeeReceiver() public {
        assertEq(hub.feeReceiver(), feeReceiver);
        _borrowAndForward(borrower, 400e6, recipient);
        assertEq(usdc.balanceOf(feeReceiver), 1e6);
    }

    function test_changedFeeReceiverIsPickedUpOnNextForward() public {
        address newReceiver = makeAddr("newReceiver");

        _borrowAndForward(borrower, 400e6, recipient);
        assertEq(usdc.balanceOf(feeReceiver), 1e6);

        hub.setFeeReceiver(newReceiver);

        _borrowAndForward(borrower, 400e6, recipient);
        assertEq(usdc.balanceOf(feeReceiver), 1e6, "old receiver gets nothing more");
        assertEq(usdc.balanceOf(newReceiver), 1e6, "new receiver gets the next fee");
    }

    function test_zeroFeeReceiverRevertsForward() public {
        hub.setFeeReceiver(address(0));
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        items[1] = _forwardItem(address(hub), borrower, recipient);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.FeeReceiverNotSet.selector, address(hub)));
        evc.batch(items);
    }

    function test_zeroFeeReceiverRevertsEvenWithZeroFee() public {
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub), 0);
        hub.setFeeReceiver(address(0));
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.FeeReceiverNotSet.selector, address(hub)));
        _borrowAndForward(borrower, 100e6, recipient);
    }

    function test_zeroFeeReceiverBlocksBorrowingWithoutForwardToo() public {
        hub.setFeeReceiver(address(0));
        // Without forward the status check fails; with forward the receiver check fails: no way to borrow.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(ERR_PENDING_NOT_FORWARDED, address(hub), 100e6));
        hub.borrow(100e6, address(feeRouter));
    }

    function test_routerAsFeeReceiverReverts() public {
        hub.setFeeReceiver(address(feeRouter));
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.FeeReceiverNotSet.selector, address(hub)));
        _borrowAndForward(borrower, 100e6, recipient);
    }

    // -- setFeeBps and sweep --------------------------------------------------------------------

    function test_setFeeBpsCapAtOneHundred() public {
        assertEq(feeRouter.MAX_FEE_BPS(), 100);

        vm.expectEmit(true, false, false, true, address(feeRouter));
        emit IPoppieFeeRouter.FeeBpsSet(address(hub), 100);
        vm.prank(ops);
        feeRouter.setFeeBps(address(hub), 100);
        assertEq(feeRouter.feeBps(address(hub)), 100);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.FeeTooHigh.selector, uint16(101)));
        feeRouter.setFeeBps(address(hub), 101);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieFeeRouter.FeeTooHigh.selector, type(uint16).max));
        feeRouter.setFeeBps(address(hub), type(uint16).max);
    }

    function test_setFeeBpsOnlyMsOps() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, MS_OPS)
        );
        feeRouter.setFeeBps(address(hub), 10);

        vm.prank(guard);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guard, MS_OPS));
        feeRouter.setFeeBps(address(hub), 10);
    }

    function test_sweepRecoversMistakenTransfer() public {
        usdc.mint(address(feeRouter), 5e6);
        address to = makeAddr("sweepTo");

        vm.expectEmit(true, true, false, true, address(feeRouter));
        emit IPoppieFeeRouter.Swept(address(usdc), to, 5e6);
        vm.prank(ops);
        feeRouter.sweep(address(usdc), to);
        assertEq(usdc.balanceOf(to), 5e6);
        assertEq(usdc.balanceOf(address(feeRouter)), 0);
    }

    function test_sweepOnlyMsOpsAndNonZeroTo() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, MS_OPS)
        );
        feeRouter.sweep(address(usdc), nobody);

        vm.prank(ops);
        vm.expectRevert(IPoppieFeeRouter.ZeroAddress.selector);
        feeRouter.sweep(address(usdc), address(0));
    }

    function test_mistakenBalanceDoesNotBreakFlow() public {
        // Tokens sent to the router by mistake stay put through a borrow and are not paid out.
        usdc.mint(address(feeRouter), 7e6);
        _borrowAndForward(borrower, 100e6, recipient);
        assertEq(usdc.balanceOf(address(feeRouter)), 7e6);
        assertEq(usdc.balanceOf(recipient), 100e6 - 0.25e6);
    }

    // -- Wiring ---------------------------------------------------------------------------------

    function test_wiring() public view {
        assertEq(feeRouter.hook(), address(hook));
        assertEq(hook.feeRouter(), address(feeRouter));
        assertEq(feeRouter.evc(), address(evc));
        assertEq(hook.evc(), address(evc));
    }

    function test_constructorsRejectZeroAddresses() public {
        vm.expectRevert(IPoppieFeeRouter.ZeroAddress.selector);
        new PoppieFeeRouter(address(0), address(evc), address(hook));
        vm.expectRevert(IPoppieFeeRouter.ZeroAddress.selector);
        new PoppieFeeRouter(admin, address(0), address(hook));
        vm.expectRevert(IPoppieFeeRouter.ZeroAddress.selector);
        new PoppieFeeRouter(admin, address(evc), address(0));
    }

    // -- Transient state never leaks across transactions ----------------------------------------

    function test_pendingIsZeroOutsideABatch() public {
        _borrowAndForward(borrower, 100e6, recipient);
        assertEq(feeRouter.pendingTotal(address(hub)), 0);
        assertEq(feeRouter.pending(address(hub), borrower), 0);

        // A reverted batch leaves nothing behind either.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = _borrowItem(hub, borrower, 100e6, address(feeRouter));
        vm.prank(borrower);
        vm.expectRevert();
        evc.batch(items);
        assertEq(feeRouter.pendingTotal(address(hub)), 0);
    }
}
