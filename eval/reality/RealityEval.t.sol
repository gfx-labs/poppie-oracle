// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Reality rTokens (Bitget) as collateral with the unmodified v1 oracle and
// adapter and the stock EulerRouter. See docs/EVAL_FINDINGS.md (RE-*). The
// token is held directly by the escrow (no wrapper) and is the oracle base.
// The EVK escrow is stood in for by an OZ ERC4626 and by a model of EVK's
// internal cash accounting (CashTrackingEscrow, shared with the Robinhood
// suite).
//   FOUNDRY_PROFILE=eval forge test --match-path 'eval/reality/*'

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {MockRealityToken} from "../mocks/MockRealityToken.sol";
import {Escrow4626, CashTrackingEscrow} from "../robinhood/RobinhoodEval.t.sol";

contract RealityEvalTest is Test {
    address internal constant USD = address(840);
    address internal constant EVC = address(0xE7C);
    uint256 internal constant WAD = 1e18;

    MockRealityToken internal t;
    Escrow4626 internal escrow;
    CashTrackingEscrow internal cashEscrow;
    PoppieEulerOracle internal o;
    PoppieEulerAdapter internal ad;
    EulerRouter internal router;

    address internal user = address(0xA11CE);
    address internal liquidator = address(0x11D);
    uint256 internal es; // user's OZ escrow shares
    uint256 internal cs; // user's cash-tracking escrow shares

    function setUp() public {
        vm.warp(1_790_000_000);
        t = new MockRealityToken();
        escrow = new Escrow4626(IERC20(address(t)));
        cashEscrow = new CashTrackingEscrow(IERC20(address(t)));

        o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(t);
        uint16[] memory c = new uint16[](1);
        c[0] = 5000;
        o.configureAssets(b, c, c);
        o.adminSetPrice(address(t), 100e18); // 1 token = 1 share = $100
        ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(t), 18);

        router = new EulerRouter(EVC, address(this));
        router.govSetResolvedVault(address(escrow), true);
        router.govSetResolvedVault(address(cashEscrow), true);
        router.govSetConfig(address(t), USD, address(ad));

        t.mint(user, 20e18);
        vm.startPrank(user);
        t.approve(address(escrow), type(uint256).max);
        t.approve(address(cashEscrow), type(uint256).max);
        es = escrow.deposit(10e18, user);
        cs = cashEscrow.deposit(10e18, user);
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

    /// Current-model keeper rule: price per token = equity x uiMultiplier.
    /// Dividends are paid in cash, so no total-return factor.
    function _keeperPrice(uint256 equity) internal view returns (uint256) {
        return equity * t.uiMultiplier() / WAD;
    }

    function _v() internal view returns (uint256) {
        return router.getQuote(es, address(escrow), USD);
    }

    function _vc() internal view returns (uint256) {
        return router.getQuote(cs, address(cashEscrow), USD);
    }

    // ── current model (since 2026-10-17) ────────────────────────────────

    /// A 4:1 split under the current implementation: balances static, value
    /// unchanged at execution for both escrow types, keeper push is 0%.
    function test_RE_current_splitIsContinuous() public {
        t.migrate();
        t.executeRebase(10000, 40000);
        assertEq(t.uiMultiplier(), 4e18);
        assertEq(t.effectiveAt(), 0, "applied at once, no schedule");
        assertEq(t.balanceOf(address(escrow)), 10e18, "raw balance unchanged");
        assertEq(_v(), 1000e18);
        assertEq(_vc(), 1000e18);
        _push(_keeperPrice(25e18));
        assertEq(_v(), 1000e18);
        assertEq(_vc(), 1000e18);
    }

    /// rHON pattern (2026-06-29): the same 2->1 action executed twice gives a
    /// cumulative 0.25 instead of 0.5. A keeper that follows the token pushes
    /// exactly -50%, which passes a 5000 bps breaker (strict >): collateral is
    /// halved. The keeper must check the multiplier against the corporate
    /// action, not just read the token.
    function test_RE_duplicateReverseSplit_followedPassesDefaultBreaker() public {
        t.migrate();
        t.executeRebase(20000, 10000);
        t.executeRebase(20000, 10000); // duplicate
        assertEq(t.uiMultiplier(), 0.25e18);
        _push(_keeperPrice(200e18)); // real equity after a 1:2 consolidation
        assertEq(_v(), 500e18, "2x undervalued, accepted");

        o.adminSetPrice(address(t), 100e18);
        o.setAssetThresholds(address(t), 4000, 5000);
        uint256 followed = _keeperPrice(200e18);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 5000, 4000)
        );
        _push(followed);
    }

    /// Cash dividend ($1 on $100). Reality pays it separately to the
    /// depositor via Merkl, or withholds it while the protocol is unsupported
    /// (RE-9). Either way the ex-date push drops 1% and nothing restores the
    /// collateral value: no multiplier change, no tokens or cash reach the
    /// escrow. Stock dividends (paid in rTokens) behave the same.
    function test_RE_cashDividend_valueDropsAndStays() public {
        t.migrate();
        uint256 bal = t.balanceOf(address(escrow));
        _push(_keeperPrice(99e18));
        assertEq(_v(), 990e18);
        vm.warp(block.timestamp + 30 days);
        _push(_keeperPrice(99e18));
        assertEq(_v(), 990e18, "not recovered");
        assertEq(t.balanceOf(address(escrow)), bal);
        assertEq(t.uiMultiplier(), WAD);
    }

    // ── legacy model (before 2026-10-17) ────────────────────────────────

    /// Legacy rebase, 4:1 forward: balances x4. OZ escrow: value x4 until the
    /// keeper pushes equity/4, then correct. EVK-style cash: cash stays at 10
    /// while the balance is 40, so after the correct push the collateral is
    /// valued at a quarter (mass liquidations), and 30 tokens sit unaccounted.
    function test_RE_legacy_forwardRebase_breaksCashAccounting() public {
        t.executeRebase(10000, 40000);
        assertEq(t.balanceOf(address(escrow)), 40e18, "holder balances x4");
        assertApproxEqRel(_v(), 4000e18, 1e12, "OZ escrow overvalued x4 before the push");
        assertEq(_vc(), 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 7500, 5000)
        );
        _push(25e18); // the correct per-token price is -75%: rejected at 5000 bps
    }

    /// Same as above, with the admin setting the correct per-token price.
    function test_RE_legacy_forwardRebase_cashEscrowUndervalued() public {
        t.executeRebase(10000, 40000);
        o.adminSetPrice(address(t), 25e18);
        assertApproxEqRel(_v(), 1000e18, 1e12, "OZ escrow correct after the price change");
        assertEq(_vc(), 250e18, "cash-tracking escrow at a quarter");
        assertEq(t.balanceOf(address(cashEscrow)), 40e18);
        assertEq(cashEscrow.cash(), 10e18);
    }

    /// Legacy 1:10 reverse rebase: balances /10. Cash-tracking escrow keeps
    /// cash 10 with 1 token held: after the correct push ($1000/token) it is
    /// valued 10x and the last holders cannot withdraw.
    function test_RE_legacy_reverseRebase_cashEscrowInsolvent() public {
        address other = address(0xB0B);
        t.mint(other, 10e18);
        vm.startPrank(other);
        t.approve(address(cashEscrow), type(uint256).max);
        uint256 so = cashEscrow.deposit(10e18, other);
        vm.stopPrank();

        t.executeRebase(100000, 10000);
        assertEq(t.balanceOf(address(cashEscrow)), 2e18);
        o.adminSetPrice(address(t), 1000e18);
        assertEq(_vc(), 10_000e18, "valued at 10 tokens it does not hold");

        vm.prank(user);
        cashEscrow.redeem(cs / 5, user, user); // takes the 2 tokens left
        vm.prank(other);
        vm.expectRevert();
        cashEscrow.redeem(so, other, other);
    }

    /// The 2026-10-17 migration on a token that had a 4:1 legacy rebase:
    /// balances drop to a quarter at the upgrade and the multiplier becomes
    /// 4. The correct per-token price goes from $25 to $100 (+300%): no
    /// breaker passes it. OZ escrow: value /4 until an admin sets the price.
    /// Cash-tracking escrow: cash 40 with 10 held, insolvent.
    function test_RE_migration_isABalanceChangingEvent() public {
        t.executeRebase(10000, 40000);
        o.adminSetPrice(address(t), 25e18);
        CashTrackingEscrow ce = new CashTrackingEscrow(IERC20(address(t)));
        router.govSetResolvedVault(address(ce), true);
        t.mint(user, 40e18);
        vm.prank(user);
        t.approve(address(ce), type(uint256).max);
        vm.prank(user);
        uint256 s = ce.deposit(40e18, user);
        assertEq(router.getQuote(s, address(ce), USD), 1000e18);

        t.migrate();
        assertEq(t.uiMultiplier(), 4e18);
        assertEq(t.balanceOf(address(ce)), 10e18, "balance /4 at the upgrade");
        assertApproxEqRel(_v(), 250e18, 1e12, "OZ escrow: 40 tokens -> 10 at $25");

        o.setAssetThresholds(address(t), 10000, 10000);
        uint256 correct = _keeperPrice(25e18);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(t), 30000, 10000)
        );
        _push(correct);

        o.adminSetPrice(address(t), uint128(_keeperPrice(25e18)));
        assertEq(router.getQuote(s, address(ce), USD), 4000e18, "cash 40 x $100: 4x overvalued");
        assertEq(ce.cash(), 40e18);
    }

    // ── issuer controls ─────────────────────────────────────────────────

    /// Freezing the escrow blocks its deposits and withdrawals; escrow shares
    /// still move (seizure stand-in). Pause behaves the same for all holders.
    function test_RE_freezeAndPauseBlockEscrowNotShares() public {
        t.setFrozen(address(escrow), true);
        vm.startPrank(user);
        vm.expectRevert(bytes("AccountIsFrozen"));
        escrow.redeem(1e18, user, user);
        escrow.transfer(liquidator, 1e18);
        vm.stopPrank();
        t.setFrozen(address(escrow), false);

        t.pause();
        vm.prank(user);
        vm.expectRevert(bytes("EnforcedPause"));
        escrow.redeem(1e18, user, user);
        assertEq(_v(), 1000e18, "pricing unaffected");
    }
}
