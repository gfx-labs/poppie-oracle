// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Fork tests against real Reality rTokens (Bitget) on Arbitrum One. Local
// fork only: nothing is broadcast. Skipped unless ARBITRUM_RPC_URL is set:
//   ARBITRUM_RPC_URL=<archive-capable RPC> FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/Reality*'
//
// The token source is unverified. Selectors, roles and behaviour were read and
// simulated on-chain on 2026-11-05 (block ~521.34M); see docs/EVAL_FINDINGS.md
// (RE-*). Three selectors have no public signature and are named here by what
// simulation shows:
//   0xe5839443 executeAction(bytes32 id, uint256 fromShares, uint256 toShares)
//   0x79c36a7f setActionRegistry(address)       (emits 0xb363a1a6.. old,new)
//   0x7b377df0 actionRegistry() returns (address)
// The suite is pinned to block 521,342,402 (2026-11-05 03:35 UTC), while
// the rSOXX 3:1 split (registry action 0x077fabc3.., effective 07:00 UTC) was
// still pending. Reality executed it at 08:30 UTC (RE-5).

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";

interface IRToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function supportsInterface(bytes4) external view returns (bool);
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
    function rebaseIndex() external view returns (uint256);
    function balanceOfUI(address) external view returns (uint256);
    function paused() external view returns (bool);
    function isDelisted() external view returns (bool);
    function isFrozen(address) external view returns (bool);
    function minter() external view returns (address);
    function vault() external view returns (address);
    function hasRole(bytes32, address) external view returns (bool);
    function getRoleMembers(bytes32) external view returns (address[] memory);
    function pause() external;
    function unpause() external;
    function delist() external;
    function freezeAccount(address[] calldata) external;
    function emergencyWithdraw(address) external;
    function mint(address, uint256) external;
}

interface IBeacon {
    function implementation() external view returns (address);
    function owner() external view returns (address);
    function upgradeTo(address) external;
}

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

contract REscrow4626 is ERC4626 {
    constructor(IERC20 a) ERC20("escrow", "e") ERC4626(a) {}
}

contract RealityArbForkTest is Test {
    IRToken internal constant SOXX = IRToken(0x8E4Ad4Ee23d909AEfcC50A93fF367C36881C6fc0);
    IRToken internal constant NVDA = IRToken(0x0a85b6EBe3C150A1979a65656E304033D62b1E12);
    IRToken internal constant CRWD = IRToken(0x21fB5867D95eACaC6836589425Aa25c9D388dC1f);

    IBeacon internal constant BEACON = IBeacon(0x9a570740FaF9C77255e389a7BcCB7D460A5f4948);
    address internal constant IMPL = 0x752C8073033046898aF127b3C78210E0D6e6C764;
    address internal constant BEACON_OWNER_SAFE = 0x7fD7A3Af05065fceEBbDa0B021206943423e4fdc; // 3-of-5
    address internal constant ADMIN_SAFE = 0xE6568007dB6E9188798AE0b65e5532F14a1ABcBB; // 3-of-5: admin + configurer
    address internal constant OPERATOR = 0x6C5b3FdAB92BD311206e873806cB30E21cd11f00; // EOA
    address internal constant REGISTRY = 0xd01f8AA971A3f4d13d52299bDD30225B1D7F40F1;
    address internal constant MINTER = 0x129Ea4DDb91C836f89Dfa9EF8102F9E505DFC4ba;
    address internal constant VAULT = 0xF880f4184CB09b826E21d5c8765Ff156da9Da876;
    address internal constant HOLDER = 0x4cAd1efBFd5F0848E0c3c14FAb23F92b2FA81F17; // ~90% of rSOXX

    bytes32 internal constant CONFIGURER_ROLE = 0xf45c97b23e2beeefda80e1ce5cb3e234aa7b6888ad5cbabb75bfd654dd8e102d;
    bytes32 internal constant OPERATOR_ROLE = 0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929;
    bytes32 internal constant MINTER_ROLE = 0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6;

    bytes32 internal constant SOXX_SPLIT = 0x077fabc3608719f0def5393d21fac276c60f762fca6cfc2b34283213f56c3a96;
    uint256 internal constant SOXX_SPLIT_EFFECTIVE = 1793862000; // 2026-11-05 07:00 UTC

    // 2026-11-05 03:35 UTC: before the rSOXX split was executed (08:30 UTC).
    // Needs an archive-capable RPC.
    uint256 internal constant FORK_BLOCK = 521_342_402;

    address internal constant USD = address(840);
    uint256 internal constant WAD = 1e18;

    address internal user = address(0xA11CE);
    address internal liquidator = address(0x11D);
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        live = true;
        vm.prank(HOLDER);
        SOXX.transfer(user, 100e18);
    }

    modifier onlyFork() {
        if (!live) vm.skip(true);
        _;
    }

    modifier soxxSplitPending() {
        if (SOXX.uiMultiplier() != WAD) vm.skip(true);
        _;
    }

    function _execute(IRToken t, bytes32 id, uint256 fromShares, uint256 toShares) internal returns (bool ok, bytes memory ret) {
        vm.prank(ADMIN_SAFE);
        (ok, ret) = address(t).call(abi.encodeWithSelector(bytes4(0xe5839443), id, fromShares, toShares));
    }

    function _escrowWith(uint256 amount) internal returns (REscrow4626 escrow, uint256 shares) {
        escrow = new REscrow4626(IERC20(address(SOXX)));
        vm.startPrank(user);
        SOXX.approve(address(escrow), type(uint256).max);
        shares = escrow.deposit(amount, user);
        vm.stopPrank();
    }

    /// Recorded state: beacon proxy on a shared beacon owned by a 3-of-5
    /// Safe; admin and configurer roles on a second 3-of-5 Safe; operator
    /// EOA; ERC-8056 interfaces; no rebase index in use; no scheduled
    /// multipliers.
    function test_fork_re_tokenFacts() public onlyFork {
        assertEq(block.chainid, 42161);
        assertEq(SOXX.decimals(), 18);
        assertEq(BEACON.implementation(), IMPL);
        assertEq(BEACON.owner(), BEACON_OWNER_SAFE);
        assertEq(ISafe(BEACON_OWNER_SAFE).getThreshold(), 3);
        assertEq(ISafe(BEACON_OWNER_SAFE).getOwners().length, 5);
        assertEq(ISafe(ADMIN_SAFE).getThreshold(), 3);
        assertEq(ISafe(ADMIN_SAFE).getOwners().length, 5);

        IRToken[3] memory ts = [SOXX, NVDA, CRWD];
        for (uint256 i; i < 3; ++i) {
            IRToken t = ts[i];
            assertTrue(t.hasRole(0x00, ADMIN_SAFE), "DEFAULT_ADMIN");
            assertTrue(t.hasRole(CONFIGURER_ROLE, ADMIN_SAFE), "CONFIGURER");
            assertTrue(t.hasRole(OPERATOR_ROLE, OPERATOR), "OPERATOR");
            assertEq(t.getRoleMembers(MINTER_ROLE).length, 0, "minting via minter() only");
            assertEq(t.minter(), MINTER);
            assertEq(t.vault(), VAULT);
            assertEq(t.rebaseIndex(), WAD, "legacy rebase index unused");
            assertEq(t.effectiveAt(), 0, "no scheduled multiplier");
            assertEq(t.newUIMultiplier(), t.uiMultiplier());
            (, bytes memory reg) = address(t).staticcall(abi.encodeWithSelector(bytes4(0x7b377df0)));
            assertEq(abi.decode(reg, (address)), REGISTRY);
        }
        assertEq(OPERATOR.code.length, 0, "operator is an EOA");
        assertEq(CRWD.uiMultiplier(), 4e18, "4:1 from the 2026-10-17 migration");

        assertTrue(SOXX.supportsInterface(0xa60bf13d), "IScaledUIAmount");
        assertTrue(SOXX.supportsInterface(0x4bd27648), "IScaledUIAmountNewUIMultiplier");
        assertTrue(SOXX.supportsInterface(0xd890fd71), "IScaledUIAmountBalances");
        assertTrue(SOXX.supportsInterface(0x57854fc3), "IScaledUIAmountConversion");
        emit log_named_uint("SOXX uiMultiplier", SOXX.uiMultiplier());
    }

    /// Full Poppie path on the real token: escrow -> rSOXX (direct route, no
    /// wrapper) priced by the v1 adapter. Reality's registered 3:1 split is
    /// executed by the configurer Safe: raw balances unchanged, router value
    /// unchanged, the keeper's per-token push is a 0% move.
    function test_fork_re_splitThroughRouterIsContinuous() public onlyFork soxxSplitPending {
        PoppieEulerOracle o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(SOXX);
        uint16[] memory c = new uint16[](1);
        c[0] = 2000;
        o.configureAssets(b, c, c);
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(SOXX), 18);
        (REscrow4626 escrow, uint256 es) = _escrowWith(10e18);
        EulerRouter router = new EulerRouter(address(0xE7C), address(this));
        router.govSetResolvedVault(address(escrow), true);
        router.govSetConfig(address(SOXX), USD, address(ad));

        uint256 equity = 900e18;
        o.adminSetPrice(address(SOXX), uint128(equity));
        uint256 v0 = router.getQuote(es, address(escrow), USD);

        (bool ok,) = _execute(SOXX, SOXX_SPLIT, 10000, 30000);
        assertTrue(ok, "execute");
        assertEq(SOXX.uiMultiplier(), 3e18, "applied at once");
        assertEq(SOXX.effectiveAt(), 0);
        assertEq(SOXX.balanceOf(address(escrow)), 10e18, "raw balance unchanged");
        assertEq(SOXX.balanceOfUI(address(escrow)), 30e18);
        assertEq(router.getQuote(es, address(escrow), USD), v0, "no jump at execution");

        uint128[] memory p = new uint128[](1);
        p[0] = uint128((equity / 3) * SOXX.uiMultiplier() / WAD);
        o.keeperPushPrices(b, p);
        assertApproxEqRel(router.getQuote(es, address(escrow), USD), v0, 1e12);
        vm.prank(user);
        assertApproxEqAbs(escrow.redeem(es, user, user), 10e18, 1, "same raw amount out");
    }

    /// Multiplier changes go through the action registry: the ratio must
    /// match the registered data hash, unknown ids revert, an action runs
    /// once, and only the configurer can execute. There is no check against
    /// the effective time: the split executes hours early.
    function test_fork_re_actionRegistryGuards() public onlyFork soxxSplitPending {
        (bool ok, bytes memory ret) = _execute(SOXX, SOXX_SPLIT, 10000, 1_000_000);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(0xee3e17dc), "InvalidDataHash: ratio must match");

        (ok, ret) = _execute(SOXX, bytes32(uint256(12345)), 10000, 20000);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(0xa947a72f), "ActionNotFound");

        vm.prank(address(0xBEEF));
        (ok,) = address(SOXX).call(abi.encodeWithSelector(bytes4(0xe5839443), SOXX_SPLIT, 10000, 30000));
        assertFalse(ok, "only configurer");

        if (block.timestamp < SOXX_SPLIT_EFFECTIVE) {
            emit log_named_uint("executed this many seconds early", SOXX_SPLIT_EFFECTIVE - block.timestamp);
        }
        (ok,) = _execute(SOXX, SOXX_SPLIT, 10000, 30000);
        assertTrue(ok, "no effective-time check");
        assertEq(SOXX.uiMultiplier(), 3e18);

        (ok, ret) = _execute(SOXX, SOXX_SPLIT, 10000, 30000);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(0x6d41cd6c), "ActionAlreadyExecuted");
    }

    /// The admin Safe can repoint a token to a different action registry,
    /// so the registry bound holds only as long as the admin keys do.
    function test_fork_re_adminCanReplaceRegistry() public onlyFork {
        address other = address(0xD0D0);
        vm.prank(address(0xBEEF));
        (bool ok,) = address(SOXX).call(abi.encodeWithSelector(bytes4(0x79c36a7f), other));
        assertFalse(ok, "non-admin rejected");

        vm.prank(ADMIN_SAFE);
        (ok,) = address(SOXX).call(abi.encodeWithSelector(bytes4(0x79c36a7f), other));
        assertTrue(ok);
        (, bytes memory reg) = address(SOXX).staticcall(abi.encodeWithSelector(bytes4(0x7b377df0)));
        assertEq(abi.decode(reg, (address)), other);
    }

    /// The beacon owner (3-of-5 Safe, no timelock) can upgrade every rToken
    /// at once; the 2026-10-17 upgrade changed every holder balance on 18
    /// tokens (RE-3).
    function test_fork_re_beaconOwnerUpgradesAllTokens() public onlyFork {
        uint256 before = NVDA.balanceOf(HOLDER);
        REscrow4626 dummy = new REscrow4626(IERC20(address(SOXX))); // any contract with code
        vm.prank(BEACON_OWNER_SAFE);
        BEACON.upgradeTo(address(dummy));
        assertEq(BEACON.implementation(), address(dummy));
        (bool ok,) = address(NVDA).staticcall(abi.encodeWithSelector(IRToken.uiMultiplier.selector));
        assertFalse(ok, "old interface gone on every token");
        assertGt(before, 0);
    }

    /// Operator pause stops all transfers, including escrow withdrawals;
    /// escrow shares still move. Only the admin Safe can unpause.
    function test_fork_re_pauseFreezesEscrowNotShares() public onlyFork {
        (REscrow4626 escrow, uint256 es) = _escrowWith(10e18);
        vm.prank(OPERATOR);
        SOXX.pause();
        assertTrue(SOXX.paused());
        vm.startPrank(user);
        vm.expectRevert(bytes4(0xd93c0665)); // EnforcedPause
        escrow.redeem(1e18, user, user);
        escrow.transfer(liquidator, es / 2); // seizure stand-in
        vm.stopPrank();
        assertEq(escrow.balanceOf(liquidator), es / 2);

        vm.prank(OPERATOR);
        vm.expectRevert();
        SOXX.unpause();
        vm.prank(ADMIN_SAFE);
        SOXX.unpause();
        assertFalse(SOXX.paused());
    }

    /// Freezing the escrow blocks transfers from and to it (and its own
    /// burns). No function was found that moves or burns a frozen balance.
    function test_fork_re_frozenEscrowCannotMoveTokens() public onlyFork {
        (REscrow4626 escrow,) = _escrowWith(10e18);
        address[] memory a = new address[](1);
        a[0] = address(escrow);
        vm.prank(ADMIN_SAFE);
        SOXX.freezeAccount(a);
        assertTrue(SOXX.isFrozen(address(escrow)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xcf8eb597), address(escrow))); // AccountIsFrozen
        escrow.redeem(1e18, user, user);
        assertEq(SOXX.balanceOf(address(escrow)), 10e18);
    }

    /// emergencyWithdraw(asset) moves only `asset` held by the token contract
    /// itself, to the vault address. It does not touch holder balances.
    function test_fork_re_emergencyWithdrawOnlyRescuesStrayTokens() public onlyFork {
        (REscrow4626 escrow,) = _escrowWith(10e18);
        vm.prank(user);
        SOXX.transfer(address(SOXX), 1e18);
        uint256 v0 = SOXX.balanceOf(VAULT);

        vm.prank(OPERATOR);
        SOXX.emergencyWithdraw(address(SOXX));
        assertEq(SOXX.balanceOf(address(SOXX)), 0);
        assertEq(SOXX.balanceOf(VAULT), v0 + 1e18);

        // The argument is the ERC-20 to rescue from the token contract, not a
        // holder: passing the escrow rescues escrow shares held by rSOXX (none).
        vm.prank(OPERATOR);
        SOXX.emergencyWithdraw(address(escrow));
        assertEq(SOXX.balanceOf(address(escrow)), 10e18, "holder balance untouched");
        vm.prank(OPERATOR);
        vm.expectRevert();
        SOXX.emergencyWithdraw(HOLDER); // an EOA is not a token
    }

    /// delist() does not stop transfers (it is read by the mint/redeem
    /// side; not verified further).
    function test_fork_re_delistDoesNotStopTransfers() public onlyFork {
        vm.prank(ADMIN_SAFE);
        SOXX.delist();
        assertTrue(SOXX.isDelisted());
        vm.prank(user);
        SOXX.transfer(liquidator, 1e18);
        assertEq(SOXX.balanceOf(liquidator), 1e18);
    }
}
