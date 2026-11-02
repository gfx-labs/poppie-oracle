// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PoppieEscrowHook} from "../../src/hooks/PoppieEscrowHook.sol";
import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";
import {IPoppieEscrowHook, MAX_DEPOSIT_PAUSE} from "../../src/interfaces/IPoppieEscrowHook.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS, K_GUARD, K_PRICE, K_CONFIRM} from "../../src/access/Roles.sol";

import {EscrowHookFixture} from "../harness/EscrowHookFixture.sol";
import {MockWrapper} from "../mocks/MockEscrowDeps.sol";

/// @notice `PoppieEscrowHook` on local EVK escrow vaults (CONTRACT_SPEC.md section 3.5, V2_PLAN.md section 4).
contract PoppieEscrowHookTest is EscrowHookFixture {
    IEVault internal escrow2;

    function setUp() public override {
        super.setUp();
        escrow2 = _createEscrow(address(stock));
        escrow2.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
    }

    function _expectUnauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    function _closedErr(IEVault v, address underlying) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IPoppieEscrowHook.AssetClosed.selector, address(v), underlying);
    }

    function _pausedErr(IEVault v) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IPoppieEscrowHook.DepositsArePaused.selector, address(v), escrowHook.depositsPausedUntil(address(v))
        );
    }

    /// @dev Runs every deposit route on `escrow` from `depositor` and expects each to revert with `err`.
    function _allRoutesRevert(bytes memory err) internal {
        address other = makeAddr("other");

        vm.startPrank(depositor);
        vm.expectRevert(err);
        escrow.deposit(1e18, depositor);
        vm.expectRevert(err);
        escrow.mint(1e18, depositor);
        vm.expectRevert(err);
        escrow.transfer(other, 1e18);
        vm.stopPrank();

        // skim: tokens sent straight to the vault, then claimed.
        stock.mint(address(escrow), 1e18);
        vm.prank(depositor);
        vm.expectRevert(err);
        escrow.skim(1e18, depositor);

        // transferFrom / transferFromMax by an approved spender.
        vm.prank(borrower);
        escrow.approve(other, type(uint256).max);
        vm.startPrank(other);
        vm.expectRevert(err);
        escrow.transferFrom(borrower, other, 1e18);
        vm.expectRevert(err);
        escrow.transferFromMax(borrower, other);
        vm.stopPrank();
    }

    /// @dev Runs every deposit route on `escrow` and expects each to succeed.
    function _allRoutesSucceed() internal {
        address other = makeAddr("other");

        vm.startPrank(depositor);
        escrow.deposit(1e18, depositor);
        escrow.mint(1e18, depositor);
        escrow.transfer(other, 1e18);
        vm.stopPrank();

        stock.mint(address(escrow), 1e18);
        vm.prank(depositor);
        escrow.skim(1e18, depositor);

        // The borrower has no debt yet, so its shares can move freely.
        vm.prank(borrower);
        escrow.approve(other, type(uint256).max);
        vm.startPrank(other);
        escrow.transferFrom(borrower, other, 1e18);
        escrow.transferFromMax(borrower, other);
        vm.stopPrank();
        assertEq(escrow.balanceOf(borrower), 0);
    }

    /// @dev Make the borrower liquidatable and return a repay amount the liquidator can use.
    function _makeLiquidatable() internal returns (uint256 maxRepay) {
        _openDebt(borrower, 900e6);
        adapter.setPrice(address(stock), 100e18);
        (maxRepay,) = hub.checkLiquidation(liquidator, borrower, address(escrow));
        assertGt(maxRepay, 0);
    }

    // -- Config ---------------------------------------------------------------------------------

    function test_isHookTargetAndConfig() public view {
        assertEq(escrowHook.isHookTarget(), IHookTarget.isHookTarget.selector);
        (address target, uint32 ops_) = escrow.hookConfig();
        assertEq(target, address(escrowHook));
        assertEq(ops_, ESCROW_HOOKED_OPS);
        assertEq(escrowHook.evc(), address(evc));
        assertEq(escrowHook.oracle(), address(stateOracle));
        assertEq(escrowHook.wrapperFactory(), address(wrapperFactory));
    }

    function test_constructorRejectsZeroAddresses() public {
        address o = address(stateOracle);
        address f = address(wrapperFactory);
        vm.expectRevert(IPoppieEscrowHook.ZeroAddress.selector);
        new PoppieEscrowHook(address(0), address(evc), o, f);
        vm.expectRevert(IPoppieEscrowHook.ZeroAddress.selector);
        new PoppieEscrowHook(admin, address(0), o, f);
        vm.expectRevert(IPoppieEscrowHook.ZeroAddress.selector);
        new PoppieEscrowHook(admin, address(evc), address(0), f);
        vm.expectRevert(IPoppieEscrowHook.ZeroAddress.selector);
        new PoppieEscrowHook(admin, address(evc), o, address(0));
    }

    // -- Oracle state ---------------------------------------------------------------------------

    function test_allRoutesOpenWhileLive() public {
        _allRoutesSucceed();
    }

    function test_allRoutesOpenWhileUnconfirmed() public {
        _setState(address(stock), IPoppieEulerOracle.PriceState.Unconfirmed);
        _allRoutesSucceed();
    }

    function test_allRoutesBlockedWhileClosed() public {
        _setState(address(stock), IPoppieEulerOracle.PriceState.Closed);
        _allRoutesRevert(_closedErr(escrow, address(stock)));
    }

    function test_reopenAllowsDepositsAgain() public {
        _setState(address(stock), IPoppieEulerOracle.PriceState.Closed);
        vm.prank(depositor);
        vm.expectRevert(_closedErr(escrow, address(stock)));
        escrow.deposit(1e18, depositor);

        _setState(address(stock), IPoppieEulerOracle.PriceState.Live);
        vm.prank(depositor);
        escrow.deposit(1e18, depositor);
    }

    function test_withdrawAndRedeemNeverBlocked() public {
        _setState(address(stock), IPoppieEulerOracle.PriceState.Closed);
        _pauseDeposits(address(escrow), MAX_DEPOSIT_PAUSE);

        vm.startPrank(borrower);
        escrow.withdraw(1e18, borrower, borrower);
        escrow.redeem(1e18, borrower, borrower);
        vm.stopPrank();
        assertEq(stock.balanceOf(borrower), 2e18);
    }

    function test_unlistedAssetFailsClosed() public {
        MockAsset t = new MockAsset();
        IEVault v = _createEscrow(address(t));
        v.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, address(t)));
        v.deposit(0, address(this));
    }

    // -- Wrapper resolution ---------------------------------------------------------------------

    function test_wrappedAssetResolvesToUnderlying() public {
        // The oracle never lists the wrapper; without resolution this would revert AssetNotListed.
        assertFalse(stateOracle.isListed(address(wrapper)));
        assertEq(wrappedEscrow.asset(), address(wrapper));

        vm.prank(depositor);
        wrappedEscrow.deposit(1e18, depositor);

        _setState(address(rebasing), IPoppieEulerOracle.PriceState.Closed);
        vm.startPrank(depositor);
        vm.expectRevert(_closedErr(wrappedEscrow, address(rebasing)));
        wrappedEscrow.deposit(1e18, depositor);
        vm.expectRevert(_closedErr(wrappedEscrow, address(rebasing)));
        wrappedEscrow.transfer(borrower, 1e18);
        // Exits still work.
        wrappedEscrow.withdraw(1e18, depositor, depositor);
        vm.stopPrank();

        // The plain escrow is unaffected by another token's closure.
        vm.prank(depositor);
        escrow.deposit(1e18, depositor);
    }

    function test_nonFactoryVaultAssetIsNotResolved() public {
        // An ERC-4626 over a listed token that the factory did not create is not unwrapped: the hook asks the
        // oracle about the 4626 itself, which is not listed, so the deposit fails closed.
        MockWrapper rogue = new MockWrapper(stock);
        assertFalse(wrapperFactory.isWrapper(address(rogue)));
        IEVault v = _createEscrow(address(rogue));
        v.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetNotListed.selector, address(rogue)));
        v.mint(0, address(this));
    }

    // -- Deposit pause --------------------------------------------------------------------------

    function test_pauseDepositsBlocksAllRoutesUntilExpiry() public {
        uint40 until = uint40(block.timestamp) + 1 hours;

        vm.expectEmit(true, true, false, true, address(escrowHook));
        emit IPoppieEscrowHook.DepositsPaused(address(escrow), until, guard);
        _pauseDeposits(address(escrow), 1 hours);
        assertEq(escrowHook.depositsPausedUntil(address(escrow)), until);

        _allRoutesRevert(_pausedErr(escrow));

        vm.warp(until - 1);
        bytes memory pausedErr = _pausedErr(escrow);
        vm.prank(depositor);
        vm.expectRevert(pausedErr);
        escrow.deposit(1e18, depositor);

        vm.warp(until);
        _allRoutesSucceed();
    }

    function test_guardCanRepauseImmediatelyAfterExpiry() public {
        _pauseDeposits(address(escrow), MAX_DEPOSIT_PAUSE);
        uint40 first = escrowHook.depositsPausedUntil(address(escrow));

        vm.warp(first);
        _pauseDeposits(address(escrow), MAX_DEPOSIT_PAUSE);
        assertEq(escrowHook.depositsPausedUntil(address(escrow)), first + MAX_DEPOSIT_PAUSE);

        bytes memory pausedErr = _pausedErr(escrow);

        vm.prank(depositor);

        vm.expectRevert(pausedErr);
        escrow.deposit(1e18, depositor);
    }

    function test_guardCanRepauseManyTimesBackToBack() public {
        for (uint256 i; i < 10; ++i) {
            _pauseDeposits(address(escrow), MAX_DEPOSIT_PAUSE);
            bytes memory pausedErr = _pausedErr(escrow);
            vm.prank(depositor);
            vm.expectRevert(pausedErr);
            escrow.deposit(1e18, depositor);
            vm.warp(escrowHook.depositsPausedUntil(address(escrow)));
        }
    }

    function test_repauseWhileActiveReplacesExpiry() public {
        _pauseDeposits(address(escrow), 10 hours);
        vm.warp(block.timestamp + 1 hours);
        _pauseDeposits(address(escrow), 2 hours);
        assertEq(escrowHook.depositsPausedUntil(address(escrow)), block.timestamp + 2 hours);
    }

    function test_pauseDepositsDurationBounds() public {
        vm.startPrank(guard);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEscrowHook.InvalidPauseDuration.selector, 0, MAX_DEPOSIT_PAUSE));
        escrowHook.pauseDeposits(_vaults(address(escrow)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieEscrowHook.InvalidPauseDuration.selector, MAX_DEPOSIT_PAUSE + 1, MAX_DEPOSIT_PAUSE
            )
        );
        escrowHook.pauseDeposits(_vaults(address(escrow)), MAX_DEPOSIT_PAUSE + 1);
        escrowHook.pauseDeposits(_vaults(address(escrow)), 1);
        escrowHook.pauseDeposits(_vaults(address(escrow)), MAX_DEPOSIT_PAUSE);
        vm.stopPrank();
    }

    function test_pauseDepositsAppliesToEveryVaultInArray() public {
        vm.prank(guard);
        escrowHook.pauseDeposits(_vaults(address(escrow), address(escrow2)), 3 hours);
        assertEq(escrowHook.depositsPausedUntil(address(escrow)), block.timestamp + 3 hours);
        assertEq(escrowHook.depositsPausedUntil(address(escrow2)), block.timestamp + 3 hours);
        assertEq(escrowHook.depositsPausedUntil(address(wrappedEscrow)), 0);
    }

    function test_depositPauseIsPerVault() public {
        _pauseDeposits(address(escrow), 1 hours);

        stock.mint(depositor, 1e18);
        vm.startPrank(depositor);
        stock.approve(address(escrow2), 1e18);
        escrow2.deposit(1e18, depositor);
        wrappedEscrow.deposit(1e18, depositor);
        vm.expectRevert(_pausedErr(escrow));
        escrow.deposit(1e18, depositor);
        vm.stopPrank();
    }

    function test_pauseDepositsOnlyGuard() public {
        _expectUnauthorized(ops, K_GUARD);
        vm.prank(ops);
        escrowHook.pauseDeposits(_vaults(address(escrow)), 1 hours);

        _expectUnauthorized(admin, K_GUARD);
        vm.prank(admin);
        escrowHook.pauseDeposits(_vaults(address(escrow)), 1 hours);
    }

    function test_revokedGuardCannotPause() public {
        vm.prank(ops);
        escrowHook.revokeRole(K_GUARD, guard);
        _expectUnauthorized(guard, K_GUARD);
        vm.prank(guard);
        escrowHook.pauseDeposits(_vaults(address(escrow)), 1 hours);
    }

    // -- Early unpause --------------------------------------------------------------------------

    function test_unpauseDepositsEndsPauseEarly() public {
        vm.prank(guard);
        escrowHook.pauseDeposits(_vaults(address(escrow), address(escrow2)), MAX_DEPOSIT_PAUSE);

        vm.expectEmit(true, true, false, false, address(escrowHook));
        emit IPoppieEscrowHook.DepositsUnpaused(address(escrow), ops);
        vm.prank(ops);
        escrowHook.unpauseDeposits(_vaults(address(escrow)));

        assertEq(escrowHook.depositsPausedUntil(address(escrow)), 0);
        assertGt(escrowHook.depositsPausedUntil(address(escrow2)), block.timestamp);

        vm.prank(depositor);
        escrow.deposit(1e18, depositor);
    }

    function test_unpauseDepositsIsNoOpWhenNotPaused() public {
        vm.recordLogs();
        vm.prank(ops);
        escrowHook.unpauseDeposits(_vaults(address(escrow)));
        assertEq(vm.getRecordedLogs().length, 0);

        // An expired pause is also left alone.
        _pauseDeposits(address(escrow), 1 hours);
        uint40 until = escrowHook.depositsPausedUntil(address(escrow));
        vm.warp(until);
        vm.recordLogs();
        vm.prank(ops);
        escrowHook.unpauseDeposits(_vaults(address(escrow)));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(escrowHook.depositsPausedUntil(address(escrow)), until);
    }

    function test_unpauseDepositsOnlyMsOps() public {
        _pauseDeposits(address(escrow), 1 hours);
        _expectUnauthorized(guard, MS_OPS);
        vm.prank(guard);
        escrowHook.unpauseDeposits(_vaults(address(escrow)));
    }

    // -- Liquidation seizure (transfer inside evc.controlCollateral) -----------------------------

    function test_liquidationSeizesCollateralDuringDepositPause() public {
        uint256 maxRepay = _makeLiquidatable();
        _pauseDeposits(address(escrow), MAX_DEPOSIT_PAUSE);

        uint256 before = escrow.balanceOf(liquidator);
        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
        assertGt(escrow.balanceOf(liquidator), before);

        // The pause still blocks an ordinary transfer by the liquidator.
        bytes memory pausedErr = _pausedErr(escrow);
        vm.prank(liquidator);
        vm.expectRevert(pausedErr);
        escrow.transfer(depositor, 1e18);
    }

    function test_liquidationSeizesCollateralWhileClosedAtHookLevel() public {
        // The real adapter reverts the mid while Closed, so liquidation cannot run then; the hook itself does not
        // stand in the way of a controlCollateral transfer.
        uint256 maxRepay = _makeLiquidatable();
        _setState(address(stock), IPoppieEulerOracle.PriceState.Closed);

        uint256 before = escrow.balanceOf(liquidator);
        vm.prank(liquidator);
        hub.liquidate(borrower, address(escrow), maxRepay, 0);
        assertGt(escrow.balanceOf(liquidator), before);
    }

    function test_batchedTransferIsNotExempt() public {
        vm.prank(depositor);
        escrow.deposit(2e18, depositor);
        _pauseDeposits(address(escrow), 1 hours);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(escrow),
            onBehalfOfAccount: depositor,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", borrower, 1e18)
        });

        bytes memory pausedErr = _pausedErr(escrow);

        vm.prank(depositor);

        vm.expectRevert(pausedErr);
        evc.batch(items);
    }

    function test_hookRejectsDirectCallFromNonVault() public {
        // A caller with no `asset()` cannot use the hook.
        vm.expectRevert();
        escrowHook.deposit(1, address(this));
    }
}

/// @notice Minimal 18-decimal token the oracle never lists.
contract MockAsset {
    string public name = "Unlisted";
    string public symbol = "UNL";
    uint8 public decimals = 18;

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice The escrow hook wired to the real `PoppieEulerOracle`: Closed by staleness and by pause both block
/// deposits.
contract PoppieEscrowHookRealOracleTest is EscrowHookFixture {
    PoppieEulerOracle internal realOracle;
    PoppieEscrowHook internal hook2;
    IEVault internal escrow3;
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");

    function setUp() public override {
        super.setUp();
        realOracle = new PoppieEulerOracle(admin);
        hook2 = new PoppieEscrowHook(admin, address(evc), address(realOracle), address(wrapperFactory));

        vm.startPrank(admin);
        realOracle.grantRole(MS_OPS, ops);
        realOracle.grantRole(K_PRICE, keeper);
        realOracle.grantRole(K_CONFIRM, confirmer);
        vm.stopPrank();

        address[] memory t = new address[](1);
        t[0] = address(stock);
        IPoppieEulerOracle.PriceClass[] memory c = new IPoppieEulerOracle.PriceClass[](1);
        vm.prank(ops);
        realOracle.listAssets(t, c);
        uint128[] memory p = new uint128[](1);
        p[0] = 200e18;
        vm.prank(keeper);
        realOracle.keeperPushPrices(t, p);
        vm.prank(confirmer);
        realOracle.confirm(address(stock), 200e18);

        escrow3 = _createEscrow(address(stock));
        escrow3.setHookConfig(address(hook2), ESCROW_HOOKED_OPS);
        vm.prank(depositor);
        stock.approve(address(escrow3), type(uint256).max);
    }

    function test_realOracleStaleAndPausedBlockDeposits() public {
        vm.prank(depositor);
        escrow3.deposit(1e18, depositor);

        bytes memory err =
            abi.encodeWithSelector(IPoppieEscrowHook.AssetClosed.selector, address(escrow3), address(stock));
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(uint8(realOracle.state(address(stock))), uint8(IPoppieEulerOracle.PriceState.Closed));
        vm.prank(depositor);
        vm.expectRevert(err);
        escrow3.deposit(1e18, depositor);

        // A fresh push within h reopens; a pause closes again.
        address[] memory t = new address[](1);
        t[0] = address(stock);
        uint128[] memory p = new uint128[](1);
        p[0] = 201e18;
        vm.prank(keeper);
        realOracle.keeperPushPrices(t, p);
        vm.prank(depositor);
        escrow3.deposit(1e18, depositor);

        vm.prank(keeper);
        realOracle.pauseAssets(t);
        vm.prank(depositor);
        vm.expectRevert(err);
        escrow3.deposit(1e18, depositor);

        // Withdrawals still work.
        vm.prank(depositor);
        escrow3.withdraw(2e18, depositor, depositor);
    }
}
