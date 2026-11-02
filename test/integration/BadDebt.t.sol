// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";

import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {FullStackFixture} from "../harness/FullStackFixture.sol";

/// @notice Loss reserve (CONTRACT_SPEC 3.8): with `CFG_DONT_SOCIALIZE_DEBT` set, debt left on an account with no
/// collateral stays there (lenders are not haircut), and the reserve repays it. The Safe Roles-module scoping of
/// `K_RESERVE` is a fork test (POP-16).
contract BadDebtIntegrationTest is FullStackFixture {
    address internal borrower = makeAddr("borrower");
    IEVault internal escrow;

    function setUp() public override {
        super.setUp();
        escrow = _listAsset(address(stock), false, IPoppieRiskSteward.RiskClass.BlueChip, prime, 200e18);
        _depositCollateral(address(stock), borrower, 10e18, prime);
        _borrow(prime, borrower, 699e6);

        // Gap down 75% at the open: Unconfirmed, then confirmed by K_CONFIRM.
        _push(address(stock), 50e18);
        _confirm(address(stock), 50e18);
    }

    function test_debtNotSocialisedAndReserveRepays() public {
        uint256 lenderAssetsBefore = prime.convertToAssets(prime.balanceOf(lender));

        _liquidate(prime, borrower, escrow);
        assertEq(escrow.balanceOf(borrower), 0, "all collateral seized");
        uint256 bad = prime.debtOf(borrower);
        assertGt(bad, 0, "bad debt remains on the account");
        // Not socialised: lenders' claim did not drop.
        assertGe(prime.convertToAssets(prime.balanceOf(lender)), lenderAssetsBefore);

        // The reserve repays it.
        usdc.mint(reserve, bad);
        vm.startPrank(reserve);
        usdc.approve(address(prime), bad);
        prime.repay(bad, borrower);
        vm.stopPrank();
        assertEq(prime.debtOf(borrower), 0);
    }
}
