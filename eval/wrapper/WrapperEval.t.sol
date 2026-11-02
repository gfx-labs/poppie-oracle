// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Design §3 C-extra: an unmodified OZ ERC4626 (decimalsOffset = 0, seed
// deposit) over a rebasing issuer token, plus the v1 adapter pricing the
// wrapper share. FOUNDRY_PROFILE=eval forge test

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {MockXStock} from "../mocks/MockXStock.sol";
import {MintableERC20} from "../mocks/MockDistributors.sol";

contract PlainWrapper is ERC4626 {
    constructor(IERC20 t) ERC20("Wrapped", "w") ERC4626(t) {}
}

contract WrapperEvalTest is Test {
    MockXStock internal x;
    PlainWrapper internal w;
    address internal constant DEAD = address(0xdEaD);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal constant USD = address(840);

    function setUp() public {
        vm.warp(1_700_000_000);
        x = new MockXStock();
        w = new PlainWrapper(IERC20(address(x)));
        // seed deposit, shares burned to DEAD
        x.mint(address(this), 1e18);
        x.approve(address(w), type(uint256).max);
        w.deposit(1e18, DEAD);
        x.mint(alice, 100e18);
        x.mint(bob, 100e18);
        vm.prank(alice);
        x.approve(address(w), type(uint256).max);
        vm.prank(bob);
        x.approve(address(w), type(uint256).max);
    }

    function test_decimalsMatchUnderlying() public view {
        assertEq(w.decimals(), x.decimals());
    }

    /// Split (multiplier x2), reverse split (x0.25), dividend reinvest (x1.02):
    /// shares never change, assets per share follow the multiplier pro rata.
    function test_rebasesAreProRata() public {
        vm.prank(alice);
        uint256 sa = w.deposit(10e18, alice);
        vm.prank(bob);
        uint256 sb = w.deposit(30e18, bob);

        x.scheduleMultiplier(2e18, block.timestamp + 1 days);
        vm.warp(block.timestamp + 1 days);
        assertEq(w.balanceOf(alice), sa, "shares unchanged");
        assertApproxEqAbs(w.convertToAssets(sa), 20e18, 2);
        assertApproxEqAbs(w.convertToAssets(sb), 60e18, 2);

        x.scheduleMultiplier(0.5e18, block.timestamp + 1 days); // 1:4 reverse split
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(w.convertToAssets(sa), 5e18, 2);
        assertApproxEqAbs(w.convertToAssets(sb), 15e18, 2);

        x.scheduleMultiplier(0.51e18, block.timestamp + 1 days); // +2% reinvested dividend
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(w.convertToAssets(sa), 5.1e18, 2);

        // everyone can still exit in full after a reverse split
        vm.startPrank(alice);
        w.redeem(sa, alice, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        w.redeem(sb, bob, bob);
        vm.stopPrank();
        assertGe(x.balanceOf(address(w)), w.convertToAssets(w.totalSupply()));
    }

    /// Rounding in the issuer token: transfer(x) can credit x - 1. OZ ERC4626
    /// mints shares for the requested amount, so each deposit leaks <= a few
    /// wei from existing holders (pro rata; never insolvency).
    function test_transferDriftIsBounded() public {
        x.scheduleMultiplier(1.1e18, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        uint256 before = x.balanceOf(address(w));
        vm.prank(alice);
        w.deposit(1e18 + 1, alice);
        uint256 received = x.balanceOf(address(w)) - before;
        assertLe(1e18 + 1 - received, 2, "credited x-1 or x-2");
        assertGt(1e18 + 1, received, "drift exists under this rounding model");

        uint256 n = 200;
        uint256 seedValue = w.convertToAssets(w.balanceOf(DEAD));
        for (uint256 i; i < n; ++i) {
            vm.prank(bob);
            w.deposit(0.1e18 + i, bob);
        }
        uint256 seedAfter = w.convertToAssets(w.balanceOf(DEAD));
        assertApproxEqAbs(seedAfter, seedValue, 3 * n, "loss to existing holders is O(wei) per deposit");
    }

    /// With a 1e18 seed, a donation attack is unprofitable and the victim
    /// loses at most one share's worth of rounding.
    function test_inflationAttackWithSeed() public {
        address attacker = address(0xBAD);
        x.mint(attacker, 1000e18);
        vm.prank(attacker);
        x.transfer(address(w), 1000e18);
        vm.prank(alice);
        uint256 s = w.deposit(1e18, alice);
        assertGt(s, 0);
        assertApproxEqAbs(w.convertToAssets(s), 1e18, 2e3, "victim keeps ~all value");
        // the donation accrues to the seed (dead) shares, not the attacker
        assertEq(x.balanceOf(attacker), 0);
    }

    /// Stablecoins sent to an OZ ERC4626 do not move share value and there is
    /// no function that can move them out.
    function test_stablecoinDividendIsStuck() public {
        MintableERC20 usdc = new MintableERC20("USDC", 6);
        vm.prank(alice);
        uint256 s = w.deposit(10e18, alice);
        uint256 v = w.convertToAssets(s);
        usdc.mint(address(w), 1_000e6);
        assertEq(w.convertToAssets(s), v);
        assertEq(usdc.balanceOf(address(w)), 1_000e6);
    }

    /// The v1 adapter prices the wrapper share directly; a split does not
    /// change the share's USD value as long as the keeper prices
    /// equity price x equity per share.
    function test_adapterPricesWrapperShareThroughSplit() public {
        PoppieEulerOracle o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(w);
        uint16[] memory c = new uint16[](1);
        c[0] = 5000;
        o.configureAssets(b, c, c);
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(w), 18);

        uint256 equity = 200e18;
        o.adminSetPrice(address(w), uint128(equity * w.convertToAssets(1e18) / 1e18));
        uint256 v0 = ad.getQuote(5e18, address(w), USD);

        x.scheduleMultiplier(4e18, block.timestamp + 1 hours); // 4:1 split
        vm.warp(block.timestamp + 1 hours);
        equity = 50e18;
        uint128[] memory p = new uint128[](1);
        p[0] = uint128(equity * w.convertToAssets(1e18) / 1e18);
        o.keeperPushPrices(b, p); // per-share price is continuous: no breaker trip
        assertApproxEqRel(ad.getQuote(5e18, address(w), USD), v0, 1e12);
    }
}
