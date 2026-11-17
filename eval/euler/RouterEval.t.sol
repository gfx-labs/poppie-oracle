// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// B7 / B8 (docs/evaluation/Contracts.md; questions in docs/legacy/Design.md §3) with the stock EulerRouter from lib/euler-price-oracle,
// wired to the unmodified v1 adapter. The EVK escrow vault is stood in for by
// an OZ ERC4626 (EulerRouter only calls asset() and convertToAssets() on a
// resolved vault). EVK account checks and liquidation (B6/B7 in full) still
// need the EVK harness. FOUNDRY_PROFILE=eval forge test

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Errors} from "euler-price-oracle/lib/Errors.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {MockXStock} from "../mocks/MockXStock.sol";

contract Vault4626 is ERC4626 {
    constructor(IERC20 t, string memory n) ERC20(n, n) ERC4626(t) {}
}

contract RouterEvalTest is Test {
    address internal constant USD = address(840);
    address internal constant EVC = address(0xE7C); // only needs to be non-zero here

    MockXStock internal x;
    Vault4626 internal wrapper; // OZ ERC4626 over the rebasing token
    Vault4626 internal escrow; // stand-in for the EVK escrow vault (asset = wrapper)
    PoppieEulerOracle internal o;
    PoppieEulerAdapter internal ad;
    EulerRouter internal router;

    address internal user = address(0xA11CE);
    uint256 internal userEscrowShares;

    function setUp() public {
        vm.warp(1_700_000_000);
        x = new MockXStock();
        wrapper = new Vault4626(IERC20(address(x)), "wX");
        escrow = new Vault4626(IERC20(address(wrapper)), "eX");

        o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](2);
        b[0] = address(wrapper);
        b[1] = address(x);
        uint16[] memory c = new uint16[](2);
        c[0] = 5000;
        c[1] = 5000;
        o.configureAssets(b, c, c);
        o.adminSetPrice(address(wrapper), 100e18); // M = 1: 1 share = 1 token = $100
        o.adminSetPrice(address(x), 100e18);
        ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(wrapper), 18);
        ad.registerBase(address(x), 18);

        router = new EulerRouter(EVC, address(this));
        router.govSetResolvedVault(address(escrow), true);

        // user: 10 tokens -> wrapper -> escrow
        x.mint(user, 10e18);
        vm.startPrank(user);
        x.approve(address(wrapper), type(uint256).max);
        uint256 ws = wrapper.deposit(10e18, user);
        wrapper.approve(address(escrow), type(uint256).max);
        userEscrowShares = escrow.deposit(ws, user);
        vm.stopPrank();
    }

    function _pushOne(address a, uint128 p) internal {
        address[] memory b = new address[](1);
        b[0] = a;
        uint128[] memory y = new uint128[](1);
        y[0] = p;
        o.keeperPushPrices(b, y);
    }

    function _value() internal view returns (uint256) {
        return router.getQuote(userEscrowShares, address(escrow), USD);
    }

    /// Path 1 (Design §2): escrow -> wrapper resolved, wrapper share priced by
    /// the adapter. The router-level value does not move when the multiplier
    /// activates; only a keeper push moves it.
    function test_B7_path1_wrapperShareIsBase_splitIsContinuous() public {
        router.govSetConfig(address(wrapper), USD, address(ad));
        assertEq(_value(), 1000e18);
        (uint256 bid, uint256 ask) = router.getQuotes(userEscrowShares, address(escrow), USD);
        assertEq(bid, ask);

        x.scheduleMultiplier(2e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);
        assertEq(_value(), 1000e18, "no on-chain jump at activation");

        // keeper: equity $50 post-split x 2 tokens per share = $100, unchanged
        _pushOne(address(wrapper), uint128(50e18 * wrapper.convertToAssets(1e18) / 1e18));
        assertApproxEqAbs(_value(), 1000e18, 1e3);
    }

    /// Path 2 (alternative): also resolve wrapper -> token and price the raw
    /// rebasing token. At activation the token count doubles on-chain while
    /// the stored price is still pre-split: collateral is 2x overvalued until
    /// the keeper pushes. Do not use this path for rebasing tokens.
    function test_B7_path2_resolvingToRebasingToken_overvaluesAtActivation() public {
        router.govSetResolvedVault(address(wrapper), true);
        router.govSetConfig(address(x), USD, address(ad));
        assertEq(_value(), 1000e18);

        x.scheduleMultiplier(2e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);
        assertApproxEqAbs(_value(), 2000e18, 1e3, "2x overvalued between activation and push");

        _pushOne(address(x), 50e18); // -50%: passes the 5000 bps breaker exactly
        assertApproxEqAbs(_value(), 1000e18, 1e3);

        // a 3:1 split on this path cannot be fixed by the keeper at all
        x.scheduleMultiplier(6e18, block.timestamp + 2 days);
        vm.warp(block.timestamp + 2 days);
        assertApproxEqAbs(_value(), 3000e18, 1e3, "3x overvalued");
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieEulerOracle.CircuitBreakerTriggered.selector, address(x), 6666, 5000)
        );
        _pushOne(address(x), 16.666e18);
    }

    /// Router precedence: a direct config wins over a resolved vault, so a
    /// stray govSetResolvedVault(wrapper) does not switch path 1 to path 2.
    function test_B7_directConfigTakesPrecedenceOverResolvedVault() public {
        router.govSetConfig(address(wrapper), USD, address(ad));
        router.govSetResolvedVault(address(wrapper), true);
        router.govSetConfig(address(x), USD, address(ad));
        x.scheduleMultiplier(2e18, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        assertEq(_value(), 1000e18);
    }

    /// Stale and paused prices revert through the router (the caller sees the
    /// oracle's own error), which is what freezes the EVK account check.
    function test_B7_staleAndPausedPropagateThroughRouter() public {
        router.govSetConfig(address(wrapper), USD, address(ad));
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        _value();
        _pushOne(address(wrapper), 101e18);
        address[] memory b = new address[](1);
        b[0] = address(wrapper);
        o.pauseAssets(b);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerOracle.AssetIsPaused.selector, address(wrapper)));
        _value();
    }

    /// B8: the router governor is a single address with full power over every
    /// route: it can overwrite a live route with any oracle, or delete it.
    /// Restricting it to unset routes needs an external governor contract.
    function test_B8_governorCanOverwriteAndDeleteLiveRoutes() public {
        router.govSetConfig(address(wrapper), USD, address(ad));
        PoppieEulerAdapter rogue = new PoppieEulerAdapter(address(o), address(this), USD, 6);
        rogue.registerBase(address(wrapper), 18);
        router.govSetConfig(address(wrapper), USD, address(rogue)); // overwrite: allowed
        assertEq(_value(), 1000e6, "route silently repointed");
        router.govSetConfig(address(wrapper), USD, address(0)); // delete: allowed
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, address(wrapper), USD));
        _value();

        vm.prank(address(0xBAD));
        vm.expectRevert(Errors.Governance_CallerNotGovernor.selector);
        router.govSetConfig(address(wrapper), USD, address(ad));
    }

    /// Path 1 and path 2 agree whenever the keeper's per-share price is
    /// consistent with the on-chain multiplier.
    function testFuzz_B7_pathsAgreeWhenPricesConsistent(uint256 m, uint256 equity, uint256 amt) public {
        m = bound(m, 0.05e18, 50e18);
        equity = bound(equity, 1e16, 1e22);
        amt = bound(amt, 1e9, userEscrowShares);
        x.scheduleMultiplier(m, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        o.adminSetPrice(address(x), uint128(equity));
        o.adminSetPrice(address(wrapper), uint128(equity * wrapper.convertToAssets(1e18) / 1e18));

        EulerRouter r1 = new EulerRouter(EVC, address(this));
        r1.govSetResolvedVault(address(escrow), true);
        r1.govSetConfig(address(wrapper), USD, address(ad));
        EulerRouter r2 = new EulerRouter(EVC, address(this));
        r2.govSetResolvedVault(address(escrow), true);
        r2.govSetResolvedVault(address(wrapper), true);
        r2.govSetConfig(address(x), USD, address(ad));

        uint256 v1 = r1.getQuote(amt, address(escrow), USD);
        uint256 v2 = r2.getQuote(amt, address(escrow), USD);
        assertApproxEqRel(v1, v2, 1e12); // 1e-6 relative: rounding only
    }
}
