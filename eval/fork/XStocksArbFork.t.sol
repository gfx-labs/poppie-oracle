// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Fork tests against the real xStocks (Backed) AAPLx token and its V2 wrapper
// on Arbitrum. Local fork only: nothing is broadcast. Skipped unless
// ARBITRUM_RPC_URL is set, e.g.
//   ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/*'
//
// Addresses and roles were read on-chain on 2026-11-02; see docs/EVAL_FINDINGS.md (XS-*).

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";

interface IBackedAutoFeeToken {
    function getCurrentMultiplier() external view returns (uint256 m, uint256 periodsPassed, uint256 nonce);
    function sharesOf(address) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function updateMultiplierValue(uint256 newM, uint256 oldM, uint256 activationTime) external;
    function lastTimeFeeApplied() external view returns (uint256);
    function periodLength() external view returns (uint256);
    function feePerPeriod() external view returns (uint256);
    function setPause(bool) external;
}

interface IWrappedBacked {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function setPause(bool) external;
}

interface IProxyAdmin {
    function getProxyImplementation(address) external view returns (address);
}

contract Escrow4626 is ERC4626 {
    constructor(IERC20 a) ERC20("escrow", "e") ERC4626(a) {}
}

contract XStocksArbForkTest is Test {
    // AAPLx on Arbitrum
    IBackedAutoFeeToken internal constant TOKEN = IBackedAutoFeeToken(0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a);
    IWrappedBacked internal constant WRAPPER = IWrappedBacked(0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f);
    address internal constant LEGACY_WRAPPER = 0x5AA7649fdbDa47De64A07aC81D64B682AF9C0724;
    address internal constant WRAPPER_IMPL = 0x76C6851ea0B2741EeDcBBED240715E8817E85583;
    address internal constant WRAPPER_PROXY_ADMIN = 0x312063009E74142339Edc92BcfF6CfCfAA958BFA;
    // Backed EOA: token burner + multiplierUpdater; holds >99% of Arbitrum supply
    address internal constant BACKED_EOA = 0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD;
    // Backed Safe (3-of-5): pauser of token and wrapper
    address internal constant BACKED_PAUSER = 0x8768cDA7A463DAe1baA6b2500EFB025ebd7FFC50;
    address internal constant USD = address(840);

    address internal user = address(0xA11CE);
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        vm.prank(BACKED_EOA);
        TOKEN.transfer(user, 100e18);
    }

    modifier onlyFork() {
        if (!live) {
            vm.skip(true);
        }
        _;
    }

    function _m() internal view returns (uint256 m) {
        (m,,) = TOKEN.getCurrentMultiplier();
    }

    /// Recorded state: proxy points at the pasted implementation; wrapper is
    /// 18 decimals over AAPLx; one wrapper share = one token share unit, so
    /// convertToAssets(1e18) == multiplier.
    function test_fork_wrapperFacts() public onlyFork {
        assertEq(IProxyAdmin(WRAPPER_PROXY_ADMIN).getProxyImplementation(address(WRAPPER)), WRAPPER_IMPL);
        assertEq(WRAPPER.asset(), address(TOKEN));
        assertEq(WRAPPER.decimals(), 18);
        assertEq(WRAPPER.convertToAssets(1e18), _m());
        assertTrue(LEGACY_WRAPPER != address(WRAPPER));
        emit log_named_uint("AAPLx multiplier", _m());
        emit log_named_uint("feePerPeriod", TOKEN.feePerPeriod());
        emit log_named_uint("periodLength", TOKEN.periodLength());
        emit log_named_uint("wrapper totalSupply", WRAPPER.totalSupply());
    }

    /// Deposit mints exactly the token share units moved; redeem never takes
    /// more share units than it burns (1:1 backing holds, dust stays in).
    function test_fork_depositRedeemKeepsOneToOneBacking() public onlyFork {
        uint256 sharesBefore = TOKEN.sharesOf(address(WRAPPER));
        vm.startPrank(user);
        TOKEN.approve(address(WRAPPER), type(uint256).max);
        uint256 minted = WRAPPER.deposit(10e18 + 7, user);
        vm.stopPrank();
        assertEq(TOKEN.sharesOf(address(WRAPPER)) - sharesBefore, minted, "1 wrapper share = 1 token share unit");

        vm.prank(user);
        WRAPPER.redeem(minted / 3, user, user);
        assertGe(TOKEN.sharesOf(address(WRAPPER)), WRAPPER.totalSupply(), "token share units >= wrapper supply");
    }

    /// Full Poppie path on the real wrapper: escrow -> wrapper (resolved) ->
    /// wrapper share priced by the v1 adapter. A scheduled 2:1 split activates:
    /// wrapper shares unchanged, convertToAssets doubles, router value does
    /// not move until the keeper pushes, and the push is continuous.
    function test_fork_splitThroughRouterIsContinuous() public onlyFork {
        // Poppie stack
        PoppieEulerOracle o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(WRAPPER);
        uint16[] memory c = new uint16[](1);
        c[0] = 2000;
        o.configureAssets(b, c, c);
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(WRAPPER), 18);
        Escrow4626 escrow = new Escrow4626(IERC20(address(WRAPPER)));
        EulerRouter router = new EulerRouter(address(0xE7C), address(this));
        router.govSetResolvedVault(address(escrow), true);
        router.govSetConfig(address(WRAPPER), USD, address(ad));

        // keeper price: equity price x equity per wrapper share
        uint256 equity = 230e18;
        o.adminSetPrice(address(WRAPPER), uint128(equity * WRAPPER.convertToAssets(1e18) / 1e18));

        // user: 10 AAPLx -> wrapper -> escrow
        vm.startPrank(user);
        TOKEN.approve(address(WRAPPER), type(uint256).max);
        uint256 ws = WRAPPER.deposit(10e18, user);
        WRAPPER.approve(address(escrow), type(uint256).max);
        uint256 es = escrow.deposit(ws, user);
        vm.stopPrank();
        uint256 v0 = router.getQuote(es, address(escrow), USD);
        assertApproxEqRel(v0, 10 * equity, 1e12);

        // Backed schedules a 2:1 split (activation must fall before the next fee period)
        uint256 mOld = _m();
        uint256 act = block.timestamp + 1 hours;
        assertLt(act, TOKEN.lastTimeFeeApplied() + TOKEN.periodLength());
        vm.prank(BACKED_EOA);
        TOKEN.updateMultiplierValue(mOld * 2, mOld, act);
        assertEq(_m(), mOld, "not active yet");

        vm.warp(act);
        assertEq(_m(), mOld * 2);
        assertEq(WRAPPER.balanceOf(address(escrow)), ws, "wrapper shares unchanged");
        assertEq(WRAPPER.convertToAssets(1e18), mOld * 2);
        assertEq(router.getQuote(es, address(escrow), USD), v0, "no jump at activation");

        // keeper: equity halves, equity per share doubles -> same per-share price (0% move)
        equity = equity / 2;
        b[0] = address(WRAPPER);
        uint128[] memory p = new uint128[](1);
        p[0] = uint128(equity * WRAPPER.convertToAssets(1e18) / 1e18);
        o.keeperPushPrices(b, p);
        assertApproxEqRel(router.getQuote(es, address(escrow), USD), v0, 1e12);

        // user exits with twice the token balance
        vm.startPrank(user);
        escrow.redeem(es, user, user);
        uint256 out = WRAPPER.redeem(ws, user, user);
        vm.stopPrank();
        assertApproxEqAbs(out, 20e18, 2);
    }

    /// Wrapper pause (Backed pauser Safe) blocks all wrapper share movement:
    /// escrow deposits and withdrawals revert. Prices are unaffected.
    function test_fork_wrapperPauseFreezesEscrowMovement() public onlyFork {
        Escrow4626 escrow = new Escrow4626(IERC20(address(WRAPPER)));
        vm.startPrank(user);
        TOKEN.approve(address(WRAPPER), type(uint256).max);
        uint256 ws = WRAPPER.deposit(5e18, user);
        WRAPPER.approve(address(escrow), type(uint256).max);
        uint256 es = escrow.deposit(ws / 2, user);
        vm.stopPrank();

        vm.prank(BACKED_PAUSER);
        WRAPPER.setPause(true);

        vm.startPrank(user);
        vm.expectRevert(bytes("WrappedBackedToken: token transfer while paused"));
        escrow.redeem(es, user, user);
        vm.expectRevert(bytes("WrappedBackedToken: token transfer while paused"));
        escrow.deposit(1, user);
        vm.stopPrank();
        assertGt(WRAPPER.convertToAssets(1e18), 0, "pricing input still readable");
    }

    /// Token pause blocks wrap/unwrap but not wrapper share transfers, so
    /// escrow operations continue.
    function test_fork_tokenPauseBlocksUnwrapOnly() public onlyFork {
        Escrow4626 escrow = new Escrow4626(IERC20(address(WRAPPER)));
        vm.startPrank(user);
        TOKEN.approve(address(WRAPPER), type(uint256).max);
        uint256 ws = WRAPPER.deposit(5e18, user);
        WRAPPER.approve(address(escrow), type(uint256).max);
        uint256 es = escrow.deposit(ws, user);
        vm.stopPrank();

        vm.prank(BACKED_PAUSER);
        TOKEN.setPause(true);

        vm.startPrank(user);
        escrow.redeem(es, user, user); // wrapper shares still move
        vm.expectRevert(bytes("BackedToken: token transfer while paused"));
        WRAPPER.redeem(ws, user, user);
        vm.stopPrank();
    }
}
