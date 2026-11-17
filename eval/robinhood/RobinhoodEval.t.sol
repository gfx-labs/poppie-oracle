// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Robinhood Stock Tokens (ERC-8056) as collateral with the unmodified v1
// oracle and adapter and the stock EulerRouter. See docs/issuerResearch/Robinhood.md
// (RH-*). The token is held directly by the escrow (no wrapper) and is the
// oracle base. The EVK escrow is stood in for by an OZ ERC4626, except in the
// burn test, which also uses a model of EVK's internal cash accounting.
//   FOUNDRY_PROFILE=eval forge test --match-path 'eval/robinhood/*'

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {MockRobinhoodStockToken} from "../mocks/MockRobinhoodStockToken.sol";

contract Escrow4626 is ERC4626 {
    constructor(IERC20 a) ERC20("escrow", "e") ERC4626(a) {}
}

/// @notice Model of EVK's cash accounting: the vault values its shares from
///         an internal `cash` counter, not from `balanceOf(this)`. Tokens
///         removed without a withdrawal (an issuer burn) are not noticed.
///         Only `asset()` and `convertToAssets()` are read by EulerRouter.
contract CashTrackingEscrow is ERC20 {
    IERC20 public immutable assetToken;
    uint256 public cash;

    constructor(IERC20 a) ERC20("cash-escrow", "ce") {
        assetToken = a;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 s = totalSupply();
        return s == 0 ? shares : shares * cash / s;
    }

    function deposit(uint256 assets, address to) external returns (uint256 shares) {
        uint256 s = totalSupply();
        shares = s == 0 ? assets : assets * s / cash;
        assetToken.transferFrom(msg.sender, address(this), assets);
        cash += assets;
        _mint(to, shares);
    }

    function redeem(uint256 shares, address to, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "owner");
        assets = convertToAssets(shares);
        _burn(owner, shares);
        cash -= assets;
        assetToken.transfer(to, assets);
    }
}

contract RobinhoodEvalTest is Test {
    address internal constant USD = address(840);
    address internal constant EVC = address(0xE7C);
    uint256 internal constant WAD = 1e18;

    MockRobinhoodStockToken internal t;
    Escrow4626 internal escrow;
    PoppieEulerOracle internal o;
    PoppieEulerAdapter internal ad;
    EulerRouter internal router;

    address internal user = address(0xA11CE);
    address internal liquidator = address(0x11D);
    uint256 internal es; // user's escrow shares

    function setUp() public {
        vm.warp(1_790_000_000);
        t = new MockRobinhoodStockToken();
        escrow = new Escrow4626(IERC20(address(t)));

        o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(t);
        uint16[] memory c = new uint16[](1);
        c[0] = 5000;
        o.configureAssets(b, c, c);
        o.adminSetPrice(address(t), 100e18); // M = 1: 1 token = 1 share = $100
        ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(t), 18);

        // Direct route: the raw token is the base. No wrapper, no resolved token.
        router = new EulerRouter(EVC, address(this));
        router.govSetResolvedVault(address(escrow), true);
        router.govSetConfig(address(t), USD, address(ad));

        t.mint(user, 10e18);
        vm.startPrank(user);
        t.approve(address(escrow), type(uint256).max);
        es = escrow.deposit(10e18, user);
        vm.stopPrank();
    }

    // ── helpers ─────────────────────────────────────────────────────────

    function _push(uint256 p) internal {
        address[] memory b = new address[](1);
        b[0] = address(t);
        uint128[] memory y = new uint128[](1);
        y[0] = uint128(p);
        o.keeperPushPrices(b, y);
    }

    /// Keeper rule: price per token = equity price x multiplier in effect now.
    function _keeperPrice(uint256 equity) internal view returns (uint256) {
        return equity * t.uiMultiplier() / WAD;
    }

    function _value() internal view returns (uint256) {
        return router.getQuote(es, address(escrow), USD);
    }

    // ── corporate actions ───────────────────────────────────────────────

    /// Forward split 4:1 (as CRWD on 2026-07-02). Raw balances never change,
    /// so the router value is unchanged at activation; the keeper's push at
    /// equity/4 x 4 is a 0% move.
    function test_RH_forwardSplitIsContinuous() public {
        assertEq(_value(), 1000e18);
        (uint256 bid, uint256 ask) = router.getQuotes(es, address(escrow), USD);
        assertEq(bid, ask);

        t.updateMultiplier(4e18, block.timestamp + 1 hours);
        assertEq(t.uiMultiplier(), WAD, "pending");
        assertEq(t.newUIMultiplier(), 4e18);
        vm.warp(t.effectiveAt());
        assertEq(t.uiMultiplier(), 4e18);
        assertEq(t.balanceOf(address(escrow)), 10e18, "raw balance unchanged");
        assertEq(t.balanceOfUI(address(escrow)), 40e18, "UI balance x4");
        assertEq(_value(), 1000e18, "no on-chain jump at activation");

        _push(_keeperPrice(25e18));
        assertEq(_value(), 1000e18);
    }

    /// Reverse split 1:10. Same: no balance change, no value change, and the
    /// correct push is a 0% move, so it needs no adminSetPrice.
    function test_RH_reverseSplitIsContinuous() public {
        t.updateMultiplier(0.1e18, block.timestamp + 1 hours);
        vm.warp(t.effectiveAt());
        assertEq(t.balanceOf(address(escrow)), 10e18);
        assertEq(_value(), 1000e18);
        _push(_keeperPrice(1000e18));
        assertEq(_value(), 1000e18);
    }

    /// Reinvested cash dividend ($1 on a $100 stock). The ex-date push dips by
    /// the dividend (1%, inside the breaker); when Robinhood raises the
    /// multiplier by the reinvested amount, the next push restores the value.
    /// Nothing is paid to the escrow.
    function test_RH_reinvestedDividendDipsThenRecovers() public {
        uint256 escrowBal = t.balanceOf(address(escrow));
        _push(_keeperPrice(99e18)); // ex-date open, multiplier not yet raised
        assertEq(_value(), 990e18);

        // reinvest $1 at $99: 1/99 extra shares per share
        t.updateMultiplier(WAD * 100 / 99, block.timestamp + 10 minutes);
        vm.warp(t.effectiveAt());
        assertEq(_value(), 990e18, "activation alone does not move value");
        _push(_keeperPrice(99e18));
        assertApproxEqAbs(_value(), 1000e18, 1e4);
        assertEq(t.balanceOf(address(escrow)), escrowBal, "no tokens or cash arrive");
    }

    /// Fuzzed: for any split or reverse-split ratio and equity price, value is
    /// unchanged at activation and the keeper's per-token push is a 0% move.
    function testFuzz_RH_anyMultiplierIsContinuous(uint256 ratio, uint256 equity) public {
        ratio = bound(ratio, 0.01e18, 100e18);
        equity = bound(equity, 1e16, 1e22);
        o.adminSetPrice(address(t), uint128(equity));
        uint256 v0 = _value();

        t.updateMultiplier(ratio, block.timestamp + 1 hours);
        vm.warp(t.effectiveAt());
        assertEq(_value(), v0);

        _push(equity * WAD / ratio * ratio / WAD); // post-split equity x multiplier
        assertApproxEqRel(_value(), v0, 1e12);
    }

    // ── wrong pushes ────────────────────────────────────────────────────

    /// A keeper that ignores the multiplier at a 4:1 split pushes -75%, which
    /// the 5000 bps breaker rejects; the name goes stale instead of wrong.
    function test_RH_mispush4to1_rejectedByBreaker() public {
        t.updateMultiplier(4e18, block.timestamp + 1 hours);
        vm.warp(t.effectiveAt());
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 7500, 5000)
        );
        _push(25e18);
    }

    /// At 2:1 the same mistake is exactly -50% and passes a 5000 bps breaker
    /// (strict >). Keeping the breaker below 1 - 1/r while the split is
    /// pending (docs/zeroContracts/Design.md, Corporate actions, item 2) rejects it.
    function test_RH_mispush2to1_passes5000_rejectedBelow() public {
        t.updateMultiplier(2e18, block.timestamp + 1 hours);
        vm.warp(t.effectiveAt());
        uint256 snap = vm.snapshotState();
        _push(50e18);
        assertEq(_value(), 500e18, "wrong price is live: 2x undervalued");
        vm.revertToState(snap);

        o.setAssetThresholds(address(t), 4000, 5000);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 5000, 4000)
        );
        _push(50e18);
    }

    /// Ignoring the multiplier at a 1:10 reverse split is +900%; it cannot
    /// pass even at the maximum thresholds. The correct push needs no admin.
    function test_RH_mispushReverseSplit_neverPasses() public {
        o.setAssetThresholds(address(t), 10000, 10000);
        t.updateMultiplier(0.1e18, block.timestamp + 1 hours);
        vm.warp(t.effectiveAt());
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 90000, 10000)
        );
        _push(1000e18);
    }

    // ── issuer powers ───────────────────────────────────────────────────

    /// An instant issuer multiplier change (any size) does not move collateral
    /// value on-chain: only the keeper can. A keeper that applied a x1000
    /// change is stopped by the breaker; a +40% one would pass, so the keeper
    /// must reject multiplier changes with no matching corporate action.
    function test_RH_rogueMultiplierDoesNotMoveValue() public {
        t.updateMultiplier(1000e18);
        assertEq(t.uiMultiplier(), 1000e18, "instant");
        assertEq(_value(), 1000e18);
        uint256 followed = _keeperPrice(100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 9_990_000, 5000)
        );
        _push(followed);

        t.updateMultiplier(1.4e18);
        _push(_keeperPrice(100e18));
        assertEq(_value(), 1400e18, "a plausible rogue change passes if the keeper follows it");
    }

    /// The scheduled overload rejects past activation times, nothing else.
    function test_RH_scheduledUpdateOnlyRejectsPast() public {
        vm.expectRevert(bytes("Effective time must not be in the past"));
        t.updateMultiplier(2e18, block.timestamp - 1);
        t.updateMultiplier(2e18, block.timestamp); // same block is allowed
        assertEq(t.uiMultiplier(), 2e18);
    }

    /// Issuer burn from the escrow, no allowance. With an OZ ERC4626 the loss
    /// is shared pro rata and the router sees it at once. With EVK-style
    /// internal cash, the router keeps the pre-burn value (collateral is
    /// overvalued) and the last holders cannot withdraw.
    function test_RH_burnFromEscrow_ozSharesLoss_cashTrackingOvervalues() public {
        t.adminBurn(address(escrow), 4e18);
        assertEq(_value(), 600e18, "OZ ERC4626: loss visible and pro rata");

        CashTrackingEscrow ce = new CashTrackingEscrow(IERC20(address(t)));
        router.govSetResolvedVault(address(ce), true);
        address other = address(0xB0B);
        t.mint(user, 10e18);
        t.mint(other, 10e18);
        vm.prank(user);
        t.approve(address(ce), type(uint256).max);
        vm.prank(user);
        uint256 su = ce.deposit(10e18, user);
        vm.startPrank(other);
        t.approve(address(ce), type(uint256).max);
        uint256 so = ce.deposit(10e18, other);
        vm.stopPrank();

        t.adminBurn(address(ce), 15e18);
        assertEq(t.balanceOf(address(ce)), 5e18);
        assertEq(router.getQuote(su, address(ce), USD), 1000e18, "still valued at pre-burn cash");

        vm.prank(user);
        ce.redeem(su / 2, user, user); // first out takes the 5 tokens left
        assertEq(t.balanceOf(address(ce)), 0);
        vm.prank(other);
        vm.expectRevert();
        ce.redeem(so, other, other); // everyone else is stuck
        assertEq(router.getQuote(so, address(ce), USD), 1000e18, "empty vault still prices its shares");
    }

    /// Token pause or a blocklisted escrow freezes escrow deposits and
    /// withdrawals. Escrow shares still move (the EVK liquidation seizure
    /// path), so seizure is not blocked; the liquidator cannot withdraw.
    function test_RH_pauseAndBlockFreezeEscrowButNotShareSeizure() public {
        t.pause();
        vm.startPrank(user);
        vm.expectRevert(bytes("paused"));
        escrow.redeem(1e18, user, user);
        escrow.transfer(liquidator, 1e18); // seizure stand-in
        vm.stopPrank();
        t.unpause();

        t.setBlocked(address(escrow), true);
        vm.startPrank(user);
        vm.expectRevert(bytes("blocked"));
        escrow.redeem(1e18, user, user);
        escrow.transfer(liquidator, 1e18);
        vm.stopPrank();
        vm.prank(liquidator);
        vm.expectRevert(bytes("blocked"));
        escrow.redeem(1e18, liquidator, liquidator);
        assertEq(_value(), 1000e18, "pricing unaffected (all 10 shares, wherever held)");
    }

    /// oraclePaused() is advisory. Keeper policy: no pushes while it is set,
    /// so the name goes stale (borrow and liquidation freeze through the
    /// router) and resumes on the first in-breaker push, without admin.
    function test_RH_oraclePausedFlag_keeperSkipsThenResumes() public {
        t.pauseOracle();
        if (!t.oraclePaused()) _push(_keeperPrice(100e18)); // keeper skips
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        _value();

        t.unpauseOracle();
        _push(_keeperPrice(103e18));
        assertEq(_value(), 1030e18);
    }
}
