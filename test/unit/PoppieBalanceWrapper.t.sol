// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {IPoppieBalanceWrapper} from "../../src/interfaces/IPoppieBalanceWrapper.sol";

import {WrapperFixture} from "../harness/WrapperFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";

/// @dev A token with a second entry point onto the same balances (like the old TUSD). Transfers through
/// `secondary` move the primary token's balances, so it is a different address that can move the underlying.
contract DoubleEntryToken is ERC20 {
    SecondaryEntry public immutable secondary;

    constructor() ERC20("Double Entry", "DBL") {
        secondary = new SecondaryEntry(this);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function delegateTransfer(address from, address to, uint256 amount) external {
        require(msg.sender == address(secondary), "only secondary");
        _transfer(from, to, amount);
    }
}

contract SecondaryEntry {
    DoubleEntryToken internal immutable primary;

    constructor(DoubleEntryToken primary_) {
        primary = primary_;
    }

    function balanceOf(address account) external view returns (uint256) {
        return primary.balanceOf(account);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        primary.delegateTransfer(msg.sender, to, amount);
        return true;
    }
}

contract PoppieBalanceWrapperTest is WrapperFixture {
    uint256 internal constant SEED = 1e18;
    uint256 internal constant OFFSET = 1e6;

    PoppieBalanceWrapper internal wStock; // plain token
    PoppieBalanceWrapper internal wRebasing; // balance-changing token
    PoppieBalanceWrapper internal wDividend; // dividend-paying token

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        wStock = _createWrapper(address(stock), SEED);
        wRebasing = _createWrapper(address(rebasing), SEED);
        wDividend = _createWrapper(address(dividend), SEED);
    }

    // -- Metadata and seed ----------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(wStock.asset(), address(stock));
        assertEq(wStock.factory(), address(wrapperFactory));
        assertEq(wStock.decimals(), 18 + 6);
        assertEq(wStock.name(), "Poppie Wrapped Mock Stock");
        assertEq(wStock.symbol(), "pwmSTK");
    }

    function test_decimalsFollowUnderlying() public {
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        PoppieBalanceWrapper w = _createWrapper(address(six), 1);
        assertEq(w.decimals(), 6 + 6);
    }

    function test_seedSharesHeldByFactory() public view {
        assertEq(wStock.totalSupply(), SEED * OFFSET);
        assertEq(wStock.balanceOf(address(wrapperFactory)), SEED * OFFSET);
        assertEq(wStock.totalAssets(), SEED);
        assertEq(stock.balanceOf(address(wrapperFactory)), 0);
        assertEq(stock.allowance(address(wrapperFactory), address(wStock)), 0);
    }

    // -- Deposit, mint, withdraw, redeem --------------------------------------------------------

    function test_depositAndRedeem() public {
        uint256 preview = wStock.previewDeposit(5e18);
        uint256 shares = _deposit(wStock, alice, 5e18);
        assertEq(shares, preview);
        assertEq(shares, 5e18 * OFFSET);
        assertEq(wStock.totalAssets(), SEED + 5e18);

        vm.prank(alice);
        uint256 assets = wStock.redeem(shares, alice, alice);
        assertEq(assets, 5e18);
        assertEq(stock.balanceOf(alice), 5e18);
        assertEq(wStock.balanceOf(alice), 0);
    }

    function test_mintAndWithdraw() public {
        uint256 shares = 3e18 * OFFSET;
        uint256 need = wStock.previewMint(shares);
        stock.mint(alice, need);
        vm.startPrank(alice);
        stock.approve(address(wStock), need);
        uint256 assets = wStock.mint(shares, alice);
        assertEq(assets, need);
        assertEq(wStock.balanceOf(alice), shares);

        uint256 burned = wStock.withdraw(need, alice, alice);
        vm.stopPrank();
        assertEq(burned, shares);
        assertEq(stock.balanceOf(alice), need);
    }

    function test_zeroDepositReverts() public {
        vm.prank(alice);
        vm.expectRevert(IPoppieBalanceWrapper.ZeroSharesMinted.selector);
        wStock.deposit(0, alice);

        vm.prank(alice);
        vm.expectRevert(IPoppieBalanceWrapper.ZeroSharesMinted.selector);
        wStock.mint(0, alice);
    }

    function test_depositTooSmallForAShareReverts() public {
        // Donate so that one share is worth more than one wei.
        stock.mint(address(wStock), 10e18 * OFFSET);
        stock.mint(alice, 1);
        vm.startPrank(alice);
        stock.approve(address(wStock), 1);
        vm.expectRevert(IPoppieBalanceWrapper.ZeroSharesMinted.selector);
        wStock.deposit(1, alice);
        vm.stopPrank();
    }

    /// Rounding favours the wrapper: deposit then redeem never returns more than was put in, whatever the state.
    function testFuzz_roundTripDepositRedeemNeverProfits(uint256 donation, uint256 amount, uint256 mult) public {
        donation = bound(donation, 0, 1e30);
        amount = bound(amount, 1, 1e30);
        mult = bound(mult, 0.1e18, 10e18);
        rebasing.mint(address(wRebasing), donation);
        _depositMaybe(wRebasing, bob, 7e18);
        rebasing.rebase(mult);

        rebasing.mint(alice, amount);
        vm.startPrank(alice);
        rebasing.approve(address(wRebasing), amount);
        try wRebasing.deposit(amount, alice) returns (uint256 shares) {
            assertLe(wRebasing.previewRedeem(shares), amount);
            uint256 out = wRebasing.redeem(shares, alice, alice);
            assertLe(out, amount);
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoppieBalanceWrapper.ZeroSharesMinted.selector);
        }
        vm.stopPrank();
    }

    /// Mint charges at least the value of the shares; withdraw burns at least the value of the assets.
    function testFuzz_roundingFavoursWrapperOnMintAndWithdraw(uint256 donation, uint256 shares, uint256 assets) public {
        donation = bound(donation, 0, 1e30);
        shares = bound(shares, 1, 1e36);
        stock.mint(address(wStock), donation);
        _depositMaybe(wStock, bob, 7e18);

        uint256 need = wStock.previewMint(shares);
        stock.mint(alice, need);
        vm.startPrank(alice);
        stock.approve(address(wStock), need);
        wStock.mint(shares, alice);
        // The shares just minted are worth no more than what was paid.
        assertLe(wStock.previewRedeem(shares), need);

        assets = bound(assets, 0, wStock.maxWithdraw(alice));
        uint256 burnPreview = wStock.previewWithdraw(assets);
        uint256 assetsBefore = wStock.totalAssets();
        uint256 supplyBefore = wStock.totalSupply();
        uint256 burned = wStock.withdraw(assets, alice, alice);
        vm.stopPrank();
        assertEq(burned, burnPreview);
        // The shares burned are worth at least the assets withdrawn, at the price before the withdrawal.
        assertGe(Math.mulDiv(burned, assetsBefore + 1, supplyBefore + OFFSET, Math.Rounding.Ceil), assets);
    }

    // -- Rebases --------------------------------------------------------------------------------

    function testFuzz_rebasesSharedProRata(uint256 a, uint256 b, uint256 num, uint256 den) public {
        a = bound(a, 1e6, 1e27);
        b = bound(b, 1e6, 1e27);
        num = bound(num, 1, 100);
        den = bound(den, 1, 100);

        uint256 sa = _deposit(wRebasing, alice, a);
        uint256 sb = _deposit(wRebasing, bob, b);
        uint256 supply = wRebasing.totalSupply();
        uint256 seedShares = wRebasing.balanceOf(address(wrapperFactory));

        rebasing.rebaseBy(num, den);

        // Share count is untouched by a rebase.
        assertEq(wRebasing.totalSupply(), supply);
        assertEq(wRebasing.balanceOf(alice), sa);
        assertEq(wRebasing.balanceOf(bob), sb);
        assertEq(wRebasing.balanceOf(address(wrapperFactory)), seedShares);

        // Each holder's claim is its share of the new balance.
        uint256 total = wRebasing.totalAssets();
        uint256 claimA = wRebasing.convertToAssets(sa);
        uint256 claimB = wRebasing.convertToAssets(sb);
        // Exact pro rata up to the virtual offset's dilution (`total * OFFSET / supply`) and one wei of rounding.
        uint256 tol = total * OFFSET / supply + 2;
        assertApproxEqAbs(claimA, total * sa / supply, tol);
        assertApproxEqAbs(claimB, total * sb / supply, tol);
        assertLe(claimA + claimB + wRebasing.convertToAssets(seedShares), total);
    }

    function test_positiveRebase_split() public {
        _deposit(wRebasing, alice, 10e18);
        _deposit(wRebasing, bob, 30e18);
        rebasing.rebase(2e18); // 2-for-1 split

        uint256 sa = wRebasing.balanceOf(alice);
        vm.prank(alice);
        uint256 out = wRebasing.redeem(sa, alice, alice);
        assertApproxEqAbs(out, 20e18, 2);

        uint256 sb = wRebasing.balanceOf(bob);
        vm.prank(bob);
        out = wRebasing.redeem(sb, bob, bob);
        assertApproxEqAbs(out, 60e18, 2);
    }

    function test_negativeRebase_reverseSplit() public {
        _deposit(wRebasing, alice, 10e18);
        _deposit(wRebasing, bob, 30e18);
        rebasing.rebase(0.5e18); // 1-for-2 reverse split

        uint256 sa = wRebasing.balanceOf(alice);
        vm.prank(alice);
        uint256 out = wRebasing.redeem(sa, alice, alice);
        assertApproxEqAbs(out, 5e18, 2);

        uint256 sb = wRebasing.balanceOf(bob);
        vm.prank(bob);
        out = wRebasing.redeem(sb, bob, bob);
        assertApproxEqAbs(out, 15e18, 2);
        // The wrapper never owes more than it holds.
        assertLe(wRebasing.convertToAssets(wRebasing.totalSupply()), wRebasing.totalAssets());
    }

    /// While the multiplier is not 1, the rebasing token can credit a wei less than sent. Shares are minted for
    /// what arrived, so other holders are never diluted.
    function testFuzz_shortTransferNeverDilutes(uint256 mult, uint256 amount) public {
        mult = bound(mult, 0.3e18, 3e18);
        amount = bound(amount, 1e6, 1e27);
        _deposit(wRebasing, bob, 50e18);
        rebasing.rebase(mult);

        uint256 bobShares = wRebasing.balanceOf(bob);
        uint256 bobBefore = wRebasing.convertToAssets(bobShares);
        uint256 balBefore = wRebasing.totalAssets();

        uint256 shares = _deposit(wRebasing, alice, amount);
        uint256 received = wRebasing.totalAssets() - balBefore;
        assertLe(received, amount);
        assertGe(wRebasing.convertToAssets(bobShares), bobBefore);
        assertLe(wRebasing.convertToAssets(shares), received);
    }

    // -- No skim / donations --------------------------------------------------------------------

    function test_donationRaisesEveryShare() public {
        uint256 shares = _deposit(wStock, alice, 10e18);
        uint256 before = wStock.convertToAssets(shares);
        stock.mint(address(wStock), 11e18); // donation
        assertGt(wStock.convertToAssets(shares), before);
        assertApproxEqAbs(wStock.convertToAssets(shares), 20e18, 1);
    }

    function test_noSkim() public {
        (bool ok,) = address(wStock).call(abi.encodeWithSignature("skim(uint256,address)", 1, alice));
        assertFalse(ok);
        (ok,) = address(wStock).call(abi.encodeWithSignature("skim()"));
        assertFalse(ok);
    }

    // -- Sweep ----------------------------------------------------------------------------------

    function test_sweepRejectsUnderlying() public {
        vm.expectRevert(IPoppieBalanceWrapper.CannotSweepUnderlying.selector);
        wStock.sweep(address(stock));
        vm.expectRevert(IPoppieBalanceWrapper.CannotSweepUnderlying.selector);
        wRebasing.sweep(address(rebasing));
    }

    function test_dividendsSweptToReserve() public {
        _deposit(wDividend, alice, 99e18);
        address[] memory holders = new address[](1);
        holders[0] = address(wDividend);
        // 0.25 USDC per token on 100 tokens.
        dividend.payDividend(holders, 0.25e6);
        assertEq(usdc.balanceOf(address(wDividend)), 25e6);

        uint256 sharesBefore = wDividend.totalSupply();
        uint256 assetsBefore = wDividend.totalAssets();

        vm.expectEmit(address(wDividend));
        emit IPoppieBalanceWrapper.Swept(address(usdc), reserve, 25e6);
        vm.prank(makeAddr("anyone"));
        uint256 amount = wDividend.sweep(address(usdc));

        assertEq(amount, 25e6);
        assertEq(usdc.balanceOf(reserve), 25e6);
        assertEq(usdc.balanceOf(address(wDividend)), 0);
        assertEq(wDividend.totalSupply(), sharesBefore);
        assertEq(wDividend.totalAssets(), assetsBefore);
    }

    function test_sweepFollowsCurrentRecipient() public {
        usdc.mint(address(wStock), 1e6);
        address newReserve = makeAddr("newReserve");
        vm.prank(timelock);
        wrapperFactory.setDividendRecipient(newReserve);

        wStock.sweep(address(usdc));
        assertEq(usdc.balanceOf(newReserve), 1e6);
        assertEq(usdc.balanceOf(reserve), 0);
    }

    function test_sweepEmptyBalance() public {
        assertEq(wStock.sweep(address(usdc)), 0);
    }

    function test_sweepOwnSharesSentByMistake() public {
        uint256 shares = _deposit(wStock, alice, 1e18);
        vm.prank(alice);
        wStock.transfer(address(wStock), shares);
        uint256 assetsBefore = wStock.totalAssets();
        assertEq(wStock.sweep(address(wStock)), shares);
        assertEq(wStock.balanceOf(reserve), shares);
        assertEq(wStock.totalAssets(), assetsBefore);
    }

    function test_sweepCannotMoveUnderlyingThroughSecondEntryPoint() public {
        DoubleEntryToken dbl = new DoubleEntryToken();
        PoppieBalanceWrapper w = _createWrapper(address(dbl), 1e18);
        _deposit(w, alice, 5e18);
        address secondary = address(dbl.secondary());
        assertEq(IERC20(secondary).balanceOf(address(w)), 6e18);
        vm.expectRevert(IPoppieBalanceWrapper.CannotSweepUnderlying.selector);
        w.sweep(secondary);
        assertEq(dbl.balanceOf(address(w)), 6e18);
    }

    /// `sweep` never moves the underlying token, after any mix of rebases, donations and deposits, and always
    /// pays the factory's current recipient.
    function testFuzz_sweepNeverMovesUnderlying(
        uint256 dep,
        uint256 donation,
        uint256 mult,
        uint256 dividendAmt,
        uint8 which,
        address caller
    ) public {
        dep = bound(dep, 1e6, 1e27);
        donation = bound(donation, 0, 1e27);
        mult = bound(mult, 0.2e18, 5e18);
        dividendAmt = bound(dividendAmt, 0, 1e15);

        _deposit(wRebasing, alice, dep);
        rebasing.rebase(mult);
        rebasing.mint(address(wRebasing), donation);
        usdc.mint(address(wRebasing), dividendAmt);
        stock.mint(address(wRebasing), dividendAmt);

        uint256 underlyingBefore = rebasing.balanceOf(address(wRebasing));
        uint256 supplyBefore = wRebasing.totalSupply();

        address[4] memory candidates = [address(usdc), address(stock), address(wRebasing), address(rebasing)];
        address token = candidates[which % 4];
        uint256 recipientBefore = token == address(rebasing) ? 0 : IERC20(token).balanceOf(reserve);
        uint256 held = token == address(rebasing) ? 0 : IERC20(token).balanceOf(address(wRebasing));

        vm.prank(caller);
        if (token == address(rebasing)) {
            vm.expectRevert(IPoppieBalanceWrapper.CannotSweepUnderlying.selector);
            wRebasing.sweep(token);
        } else {
            uint256 amount = wRebasing.sweep(token);
            assertEq(amount, held);
            assertEq(IERC20(token).balanceOf(reserve), recipientBefore + held);
            assertEq(IERC20(token).balanceOf(address(wRebasing)), 0);
        }

        assertEq(rebasing.balanceOf(address(wRebasing)), underlyingBefore);
        assertEq(wRebasing.totalSupply(), supplyBefore);
    }

    // -- Pricing through escrow -> wrapper -> token ---------------------------------------------

    function test_pricingThroughEscrowWrapperToken() public {
        MockPriceAdapter adapter = new MockPriceAdapter();
        adapter.setPrice(address(rebasing), 200e18); // $200 per token
        router.govSetConfig(address(rebasing), USD, address(adapter));
        router.govSetResolvedVault(address(wRebasing), true);

        IEVault escrow = _createEscrow(address(wRebasing));
        router.govSetResolvedVault(address(escrow), true);

        uint256 shares = _deposit(wRebasing, alice, 10e18);
        vm.startPrank(alice);
        wRebasing.approve(address(escrow), shares);
        uint256 escrowShares = escrow.deposit(shares, alice);
        vm.stopPrank();

        assertApproxEqRel(router.getQuote(escrowShares, address(escrow), USD), 2000e18, 1e9);

        rebasing.rebase(3e18); // 3-for-1 split: same holder value in tokens x3, price feed unchanged here
        assertApproxEqRel(router.getQuote(escrowShares, address(escrow), USD), 6000e18, 1e9);

        rebasing.rebase(0.5e18); // net reverse split
        assertApproxEqRel(router.getQuote(escrowShares, address(escrow), USD), 1000e18, 1e9);
    }

    // -- Helpers --------------------------------------------------------------------------------

    function _depositMaybe(PoppieBalanceWrapper w, address user, uint256 amount) internal {
        MockERC20(w.asset()).mint(user, amount);
        vm.startPrank(user);
        IERC20(w.asset()).approve(address(w), amount);
        try w.deposit(amount, user) {} catch {}
        vm.stopPrank();
    }
}
