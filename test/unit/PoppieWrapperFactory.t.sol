// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {PoppieWrapperFactory} from "../../src/wrapper/PoppieWrapperFactory.sol";
import {IPoppieWrapperFactory} from "../../src/interfaces/IPoppieWrapperFactory.sol";
import {IPoppieBalanceWrapper} from "../../src/interfaces/IPoppieBalanceWrapper.sol";
import {MS_OPS} from "../../src/access/Roles.sol";

import {WrapperFixture} from "../harness/WrapperFixture.sol";

contract PoppieWrapperFactoryTest is WrapperFixture {
    function test_constructor() public view {
        assertTrue(wrapperFactory.hasRole(wrapperFactory.DEFAULT_ADMIN_ROLE(), timelock));
        assertEq(wrapperFactory.dividendRecipient(), reserve);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(IPoppieWrapperFactory.ZeroAddress.selector);
        new PoppieWrapperFactory(timelock, address(0));
        vm.expectRevert(IPoppieWrapperFactory.ZeroAddress.selector);
        new PoppieWrapperFactory(address(0), reserve);
    }

    function test_createWrapper() public {
        stock.mint(deployer, 5e18);
        vm.startPrank(deployer);
        stock.approve(address(wrapperFactory), 5e18);
        address predicted = _predict(address(stock));

        vm.expectEmit(address(wrapperFactory));
        emit IPoppieWrapperFactory.WrapperCreated(address(stock), predicted, deployer, 2e18);
        address w = wrapperFactory.createWrapper(address(stock), 2e18);
        vm.stopPrank();

        assertEq(w, predicted);
        assertTrue(wrapperFactory.isWrapper(w));
        assertEq(wrapperFactory.wrapperOf(address(stock)), w);
        assertFalse(wrapperFactory.isWrapper(address(stock)));
        assertEq(wrapperFactory.wrapperOf(address(usdc)), address(0));

        // Seed pulled from the caller, deposited, shares locked in the factory.
        assertEq(stock.balanceOf(deployer), 3e18);
        assertEq(stock.balanceOf(w), 2e18);
        assertEq(PoppieBalanceWrapper(w).balanceOf(address(wrapperFactory)), 2e18 * 1e6);
        assertEq(PoppieBalanceWrapper(w).totalSupply(), 2e18 * 1e6);
        assertEq(PoppieBalanceWrapper(w).factory(), address(wrapperFactory));
        assertEq(PoppieBalanceWrapper(w).asset(), address(stock));
    }

    function test_oneWrapperPerToken() public {
        PoppieBalanceWrapper w = _createWrapper(address(stock), 1e18);
        stock.mint(deployer, 1e18);
        vm.startPrank(deployer);
        stock.approve(address(wrapperFactory), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieWrapperFactory.WrapperAlreadyExists.selector, address(stock), address(w))
        );
        wrapperFactory.createWrapper(address(stock), 1e18);
        vm.stopPrank();
    }

    function test_zeroSeedReverts() public {
        vm.prank(deployer);
        vm.expectRevert(IPoppieWrapperFactory.ZeroSeed.selector);
        wrapperFactory.createWrapper(address(stock), 0);
    }

    function test_zeroTokenReverts() public {
        vm.prank(deployer);
        vm.expectRevert(IPoppieWrapperFactory.ZeroAddress.selector);
        wrapperFactory.createWrapper(address(0), 1);
    }

    function test_seedWithoutApprovalReverts() public {
        stock.mint(deployer, 1e18);
        vm.prank(deployer);
        vm.expectRevert();
        wrapperFactory.createWrapper(address(stock), 1e18);
        assertEq(wrapperFactory.wrapperOf(address(stock)), address(0));
    }

    function test_oneWeiSeed() public {
        PoppieBalanceWrapper w = _createWrapper(address(stock), 1);
        assertEq(w.totalSupply(), 1e6);
        assertEq(w.totalAssets(), 1);
    }

    /// Creation is callable by any address (the router governor verifies what gets registered).
    function testFuzz_anyoneCanCreate(address caller, uint256 seed) public {
        vm.assume(caller != address(0) && caller != address(wrapperFactory));
        seed = bound(seed, 1, 1e30);
        stock.mint(caller, seed);
        vm.startPrank(caller);
        stock.approve(address(wrapperFactory), seed);
        address w = wrapperFactory.createWrapper(address(stock), seed);
        vm.stopPrank();
        assertTrue(wrapperFactory.isWrapper(w));
        assertEq(PoppieBalanceWrapper(w).balanceOf(address(wrapperFactory)), seed * 1e6);
        assertEq(PoppieBalanceWrapper(w).balanceOf(caller), 0);
    }

    /// A rebasing token may deliver a wei less than the seed; only what arrived is deposited.
    function test_seedOfRebasingTokenWithShortTransfer() public {
        rebasing.rebase(3e18);
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18 + 1);
        assertGt(w.totalSupply(), 0);
        assertEq(rebasing.balanceOf(address(wrapperFactory)), 0);
        assertEq(rebasing.allowance(address(wrapperFactory), address(w)), 0);
    }

    /// Tokens donated to the predicted address before creation stay in the wrapper (they back the locked seed and
    /// every later share); a seed too small to mint a share reverts, so the creator just uses a larger seed.
    function test_donationBeforeCreation() public {
        address predicted = _predict(address(stock));
        stock.mint(predicted, 1e18);

        stock.mint(deployer, 1);
        vm.startPrank(deployer);
        stock.approve(address(wrapperFactory), 1);
        vm.expectRevert(IPoppieBalanceWrapper.ZeroSharesMinted.selector);
        wrapperFactory.createWrapper(address(stock), 1);
        vm.stopPrank();

        PoppieBalanceWrapper w = _createWrapper(address(stock), 1e18);
        assertEq(address(w), predicted);
        assertEq(w.totalAssets(), 2e18);
        // The donation priced the seed's shares, so shares are coarser: a later depositor's rounding loss is at
        // most one share's worth (about donation / 1e6 here), and the donor lost the whole donation.
        uint256 shareValue = w.totalAssets() / w.totalSupply() + 1;
        uint256 shares = _deposit(w, makeAddr("alice"), 1e18);
        assertLe(w.convertToAssets(shares), 1e18);
        assertApproxEqAbs(w.convertToAssets(shares), 1e18, shareValue + 1);
    }

    function test_seedSharesStayLocked() public {
        PoppieBalanceWrapper w = _createWrapper(address(stock), 1e18);
        uint256 seedShares = w.balanceOf(address(wrapperFactory));
        address alice = makeAddr("alice");
        uint256 shares = _deposit(w, alice, 4e18);
        vm.prank(alice);
        w.redeem(shares, alice, alice);
        assertEq(w.balanceOf(address(wrapperFactory)), seedShares);
        assertEq(w.allowance(address(wrapperFactory), alice), 0);
    }

    // -- Dividend recipient ---------------------------------------------------------------------

    function test_setDividendRecipient() public {
        address next = makeAddr("next");
        vm.expectEmit(address(wrapperFactory));
        emit IPoppieWrapperFactory.DividendRecipientSet(reserve, next);
        vm.prank(timelock);
        wrapperFactory.setDividendRecipient(next);
        assertEq(wrapperFactory.dividendRecipient(), next);
    }

    function test_setDividendRecipientRejectsZero() public {
        vm.prank(timelock);
        vm.expectRevert(IPoppieWrapperFactory.ZeroAddress.selector);
        wrapperFactory.setDividendRecipient(address(0));
    }

    function testFuzz_setDividendRecipientAdminOnly(address caller) public {
        vm.assume(caller != timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, wrapperFactory.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(caller);
        wrapperFactory.setDividendRecipient(caller);
    }

    function test_msOpsCannotSetDividendRecipient() public {
        address ops = makeAddr("ops");
        vm.startPrank(timelock);
        wrapperFactory.grantRole(MS_OPS, ops);
        vm.stopPrank();
        bytes32 adminRole = wrapperFactory.DEFAULT_ADMIN_ROLE();
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, adminRole)
        );
        wrapperFactory.setDividendRecipient(ops);
    }

    // -- Mocks available to other tickets ------------------------------------------------------

    function test_mockTokens() public {
        // Multiplier token: balances fixed, multiplier published.
        multiplierToken.mint(address(this), 1e18);
        multiplierToken.setMultiplier(2e18);
        assertEq(multiplierToken.balanceOf(address(this)), 1e18);
        assertEq(multiplierToken.multiplier(), 2e18);

        // Rebasing token: balances follow the multiplier.
        rebasing.mint(address(this), 1e18);
        rebasing.rebase(1.5e18);
        assertEq(rebasing.balanceOf(address(this)), 1.5e18);

        // Dividend token: pays the payout token to holders.
        dividend.mint(address(this), 4e18);
        address[] memory holders = new address[](1);
        holders[0] = address(this);
        dividend.payDividend(holders, 1e6);
        assertEq(usdc.balanceOf(address(this)), 4e6);
    }

    function _predict(address token) internal view returns (address) {
        bytes memory init = abi.encodePacked(type(PoppieBalanceWrapper).creationCode, abi.encode(token));
        return vm.computeCreate2Address(bytes32(uint256(uint160(token))), keccak256(init), address(wrapperFactory));
    }
}
