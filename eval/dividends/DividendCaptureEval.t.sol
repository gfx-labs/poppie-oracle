// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// DIV-1 in docs/evaluation/Contracts.md: the test-only DividendCaptureWrapper
// prototype captures pushed and claim-based cash dividends as protocol
// revenue, cannot leak the underlying, and prices unchanged through the v1
// adapter and EulerRouter. FOUNDRY_PROFILE=eval forge test

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {DividendCaptureWrapper} from "../prototypes/DividendCaptureWrapper.sol";
import {
    MintableERC20,
    MockClaimDistributor,
    MaliciousDistributor,
    ReenteringDistributor
} from "../mocks/MockDistributors.sol";

contract Escrow4626 is ERC4626 {
    constructor(IERC20 t) ERC20("e", "e") ERC4626(t) {}
}

contract DividendCaptureEvalTest is Test {
    address internal constant USD = address(840);
    address internal reserve = address(0x5AFE);
    address internal operator = address(0x0A0A);
    address internal user = address(0xA11CE);

    MintableERC20 internal stock; // non-rebasing, cash-dividend equity token
    MintableERC20 internal usdc;
    DividendCaptureWrapper internal w;

    function setUp() public {
        vm.warp(1_700_000_000);
        stock = new MintableERC20("STOCK", 18);
        usdc = new MintableERC20("USDC", 6);
        w = new DividendCaptureWrapper(IERC20(address(stock)), "dcSTOCK", "dcSTOCK", reserve, operator);
        // seed
        stock.mint(address(this), 1e18);
        stock.approve(address(w), type(uint256).max);
        w.deposit(1e18, address(0xdEaD));
        // user position
        stock.mint(user, 10e18);
        vm.startPrank(user);
        stock.approve(address(w), type(uint256).max);
        w.deposit(10e18, user);
        vm.stopPrank();
    }

    function test_pushedDividend_sweptToReserve_shareValueUnchanged() public {
        uint256 v = w.convertToAssets(w.balanceOf(user));
        usdc.mint(address(w), 5_500e6); // issuer pushes cash to the holder of record
        vm.prank(address(0xF00)); // sweep is permissionless
        assertEq(w.sweep(address(usdc)), 5_500e6);
        assertEq(usdc.balanceOf(reserve), 5_500e6);
        assertEq(w.convertToAssets(w.balanceOf(user)), v, "dividend is revenue, not share value");
    }

    function test_sweepUnderlyingReverts() public {
        vm.expectRevert(DividendCaptureWrapper.CannotSweepUnderlying.selector);
        w.sweep(address(stock));
    }

    function test_claimBasedDividend() public {
        MockClaimDistributor d = new MockClaimDistributor(IERC20(address(usdc)));
        usdc.mint(address(d), 1_000e6);
        d.setEntitlement(address(w), 1_000e6);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DividendCaptureWrapper.DistributorNotAllowed.selector, address(d)));
        w.claim(address(d), abi.encodeCall(d.claim, ()));

        vm.startPrank(operator);
        w.setDistributor(address(d), true);
        w.claim(address(d), abi.encodeCall(d.claim, ()));
        vm.stopPrank();
        w.sweep(address(usdc));
        assertEq(usdc.balanceOf(reserve), 1_000e6);
    }

    function test_claimOnlyOperator() public {
        vm.expectRevert(DividendCaptureWrapper.OnlyOperator.selector);
        w.claim(address(1), "");
        vm.expectRevert(DividendCaptureWrapper.OnlyOperator.selector);
        w.setDistributor(address(1), true);
    }

    function test_underlyingAndSelfCannotBeAllowlisted() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(DividendCaptureWrapper.DistributorNotAllowed.selector, address(stock)));
        w.setDistributor(address(stock), true);
        vm.expectRevert(abi.encodeWithSelector(DividendCaptureWrapper.DistributorNotAllowed.selector, address(w)));
        w.setDistributor(address(w), true);
        vm.stopPrank();
    }

    /// A hostile distributor cannot pull the underlying: the wrapper never
    /// grants allowances, and the post-call balance check is a backstop.
    function test_maliciousDistributorCannotTakeUnderlying() public {
        MaliciousDistributor m = new MaliciousDistributor(IERC20(address(stock)));
        uint256 bal = stock.balanceOf(address(w));
        vm.startPrank(operator);
        w.setDistributor(address(m), true);
        vm.expectRevert(); // ClaimFailed(ERC20InsufficientAllowance)
        w.claim(address(m), abi.encodeCall(m.claim, ()));
        vm.stopPrank();
        assertEq(stock.balanceOf(address(w)), bal);
    }

    /// Re-entering share accounting during a claim is blocked.
    function test_reentrantDistributorBlocked() public {
        ReenteringDistributor r = new ReenteringDistributor();
        vm.startPrank(operator);
        w.setDistributor(address(r), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendCaptureWrapper.ClaimFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        w.claim(address(r), abi.encodeCall(r.claim, (address(w), 1)));
        vm.stopPrank();
    }

    /// End to end: escrow -> capture wrapper (resolved), wrapper share priced
    /// by the v1 adapter. At the ex-date the keeper pushes the ex-dividend
    /// price; the drop is the dividend the protocol captures.
    function test_endToEnd_routerAdapter_exDividendDrop() public {
        PoppieEulerOracle o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(w);
        uint16[] memory c = new uint16[](1);
        c[0] = 3000;
        o.configureAssets(b, c, c);
        o.adminSetPrice(address(w), 100e18);
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(w), 18);

        Escrow4626 escrow = new Escrow4626(IERC20(address(w)));
        EulerRouter router = new EulerRouter(address(0xE7C), address(this));
        router.govSetResolvedVault(address(escrow), true);
        router.govSetConfig(address(w), USD, address(ad));

        vm.startPrank(user);
        w.approve(address(escrow), type(uint256).max);
        uint256 es = escrow.deposit(w.balanceOf(user), user);
        vm.stopPrank();
        assertEq(router.getQuote(es, address(escrow), USD), 1000e18);

        // ex-date: $2 dividend per share; equity opens $98
        uint128[] memory p = new uint128[](1);
        p[0] = 98e18;
        o.keeperPushPrices(b, p);
        assertEq(router.getQuote(es, address(escrow), USD), 980e18);

        // pay date: issuer pays $2 x 11 shares (incl. seed) to the wrapper
        usdc.mint(address(w), 22e6);
        w.sweep(address(usdc));
        assertEq(usdc.balanceOf(reserve), 22e6);
    }
}
