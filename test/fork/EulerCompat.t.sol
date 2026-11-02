// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IGovernance, IBorrowing} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {Errors as EVKErrors} from "evk/EVault/shared/Errors.sol";

import {AssetConfig, Mechanism, ListedAsset} from "../../script/lib/Types.sol";
import {IEulerEarnFactoryMinimal, IEulerEarnMinimal} from "../../script/lib/ExternalInterfaces.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";
import {IPoppieHubHook} from "../../src/interfaces/IPoppieHubHook.sol";
import {IPoppieEscrowHook} from "../../src/interfaces/IPoppieEscrowHook.sol";
import {PoppieFeeRouter} from "../../src/fee/PoppieFeeRouter.sol";

import {ForkBase, Arbitrum} from "./ForkBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice POP-12 de-risk spike on an Arbitrum fork: canonical Euler versions, whether Euler Earn accepts hooked
/// hubs, the EVK constraints the design relies on (re-verified on the canonical implementation), and gas with
/// 300 and 500 collaterals in one hub (steward listing, `LTVList()`, the canonical lenses, account checks).
contract EulerCompatForkTest is ForkBase {
    function setUp() public {
        if (!_forkAndDeploy()) vm.skip(true);
    }

    // -- 1. Versions ----------------------------------------------------------------------------

    function test_canonicalVersions() public view {
        assertEq(GenericFactory(Arbitrum.EVAULT_FACTORY).implementation(), Arbitrum.EVAULT_IMPLEMENTATION);
        // Hubs created through the canonical factory run the canonical implementation.
        assertTrue(GenericFactory(Arbitrum.EVAULT_FACTORY).isProxy(d.hubs[0]));
        assertEq(IEVault(d.hubs[0]).EVC(), Arbitrum.EVC);
        assertEq(IEVault(d.hubs[0]).permit2Address(), Arbitrum.PERMIT2);
        assertEq(IEVault(d.hubs[0]).protocolConfigAddress(), Arbitrum.PROTOCOL_CONFIG);
        assertEq(
            IEulerEarnFactoryMinimal(Arbitrum.EULER_EARN_FACTORY).supportedPerspective(),
            Arbitrum.EVK_FACTORY_PERSPECTIVE
        );
        // The full deployment passes ConfigCheck against canonical Euler, Earn vaults included.
        assertEq(d.earns.length, 2);
    }

    function test_configCheckCleanOnFork() public {
        _assertNoDiff(checkScript.checkDeployment(_cfg(), d));
    }

    // -- 2. Euler Earn accepts hooked hubs ------------------------------------------------------

    function test_earnAcceptsHookedHubs() public view {
        IEulerEarnFactoryMinimal f = IEulerEarnFactoryMinimal(Arbitrum.EULER_EARN_FACTORY);
        for (uint256 i; i < d.hubs.length; ++i) {
            (address target, uint32 ops) = IEVault(d.hubs[i]).hookConfig();
            assertEq(target, d.hubHook);
            assertTrue(ops != 0);
            bool allowed = f.isStrategyAllowed(d.hubs[i]);
            console.log("Earn isStrategyAllowed(hooked hub)", i, allowed);
            assertTrue(allowed, "Earn rejects a hooked hub");
        }
        // Prime Earn supplies Prime; Yield Earn supplies all four.
        assertEq(IEulerEarnMinimal(d.earns[0]).supplyQueueLength(), 1);
        assertEq(IEulerEarnMinimal(d.earns[1]).supplyQueueLength(), 4);
        assertEq(IEulerEarnMinimal(d.earns[1]).curator(), cfg.msOps);
        assertTrue(IEulerEarnMinimal(d.earns[1]).isAllocator(cfg.kAlloc));
        assertEq(IEulerEarnMinimal(d.earns[1]).pendingOwner(), d.timelock);
    }

    /// @dev An Earn deposit reaches a hooked hub: Earn's supply path (deposit, no borrow) passes the hub's vault
    /// status check hook.
    function test_earnDepositFlowsIntoHookedHub() public {
        address user = makeAddr("earnUser");
        deal(Arbitrum.USDC, user, 1_000e6);
        uint256 before = IEVault(d.hubs[0]).balanceOf(d.earns[0]);
        vm.startPrank(user);
        IERC20(Arbitrum.USDC).approve(d.earns[0], 1_000e6);
        (bool ok, bytes memory ret) =
            d.earns[0].call(abi.encodeWithSignature("deposit(uint256,address)", 1_000e6, user));
        vm.stopPrank();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        assertGt(IEVault(d.hubs[0]).balanceOf(d.earns[0]), before);
    }

    // -- 3. EVK constraints on the canonical implementation -------------------------------------

    function _oneAsset() internal returns (address token, IEVault escrow) {
        MockERC20 t = new MockERC20("Fork Stock", "fSTK", 18);
        t.mint(deployer, 1e18);
        AssetConfig[] memory a = new AssetConfig[](1);
        a[0] = AssetConfig("fSTK", address(t), Mechanism.Multiplier, 0, 0, 1e18, 1_000_000e18);
        ListedAsset[] memory l = _listViaScripts(a);
        _goLive(address(t), 200e18);
        return (address(t), IEVault(l[0].escrow));
    }

    function _depositCollateral(address token, IEVault escrow, address who, uint256 amount, IEVault hub) internal {
        MockERC20(token).mint(who, amount);
        vm.startPrank(who);
        IERC20(token).approve(address(escrow), amount);
        escrow.deposit(amount, who);
        IEVC(Arbitrum.EVC).enableCollateral(who, address(escrow));
        IEVC(Arbitrum.EVC).enableController(who, address(hub));
        vm.stopPrank();
    }

    function test_constraint_ltvRaiseIsInstantRampRejected() public {
        (, IEVault escrow) = _oneAsset();
        IEVault prime = IEVault(d.hubs[0]);
        vm.prank(d.timelock); // Governor wildcard
        (bool ok, bytes memory ret) = d.governor
            .call(
                abi.encodePacked(
                    abi.encodeCall(IGovernance.setLTV, (address(escrow), 3600, 4000, 1 days)), address(prime)
                )
            );
        assertFalse(ok);
        assertEq(bytes4(ret), EVKErrors.E_LTVLiquidation.selector);
    }

    function test_constraint_rampRestartsAndStewardPreservesIt() public {
        (address token, IEVault escrow) = _oneAsset();
        IEVault prime = IEVault(d.hubs[0]);
        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](1);
        c[0] = IPoppieRiskSteward.LiquidationLtvChange(address(prime), token, 3250, 72 hours);
        vm.prank(cfg.kTighten);
        IPoppieRiskSteward(d.steward).lowerLiquidationLTV(c);
        (,,, uint48 end,) = prime.LTVFull(address(escrow));
        vm.warp(block.timestamp + 10 hours);
        IPoppieRiskSteward.BorrowLtvChange[] memory b = new IPoppieRiskSteward.BorrowLtvChange[](1);
        b[0] = IPoppieRiskSteward.BorrowLtvChange(address(prime), token, 1000);
        vm.prank(cfg.kTighten);
        IPoppieRiskSteward(d.steward).lowerBorrowLTV(b);
        (,,, uint48 end2,) = prime.LTVFull(address(escrow));
        assertEq(end2, end, "ramp end moved");
    }

    function test_constraint_hookedOperationsOnCanonicalEvk() public {
        (address token, IEVault escrow) = _oneAsset();
        IEVault prime = IEVault(d.hubs[0]);
        address b = makeAddr("borrower");
        _depositCollateral(token, escrow, b, 10e18, prime);

        // Status-check hook: a borrow that is not forwarded fails at the end of the batch.
        IEVC.BatchItem[] memory one = new IEVC.BatchItem[](1);
        one[0] = IEVC.BatchItem(address(prime), b, 0, abi.encodeCall(IBorrowing.borrow, (100e6, d.feeRouter)));
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.PendingNotForwarded.selector, address(prime), 100e6));
        IEVC(Arbitrum.EVC).batch(one);

        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(IPoppieHubHook.ReceiverNotFeeRouter.selector, b));
        prime.borrow(1e6, b);

        _borrow(prime, b, 600e6);
        assertEq(prime.debtOf(b), 600e6);
        uint16 feeBps = PoppieFeeRouter(d.feeRouter).feeBps(address(prime));
        assertEq(IERC20(Arbitrum.USDC).balanceOf(cfg.hubs[0].feeReceiver), (600e6 * uint256(feeBps) + 9999) / 10_000);
    }

    function test_constraint_liquidationSeizesThroughTransferHookDuringDepositPause() public {
        (address token, IEVault escrow) = _oneAsset();
        IEVault prime = IEVault(d.hubs[0]);
        address b = makeAddr("borrower");
        _depositCollateral(token, escrow, b, 10e18, prime);
        _borrow(prime, b, 699e6);
        _push(token, 185e18);
        address[] memory v = new address[](1);
        v[0] = address(escrow);
        vm.prank(cfg.kGuard);
        IPoppieEscrowHook(d.escrowHook).pauseDeposits(v, 24 hours);
        _liquidate(prime, b, address(escrow));
        assertGt(escrow.balanceOf(liquidator), 0);
    }

    // -- 4. Scale: 300 and 500 collaterals in one hub -------------------------------------------

    function test_scale_300_collaterals() public {
        _measure(IEVault(d.hubs[1]), _listMany(300, 0), "300", true);
    }

    function test_scale_500_collaterals() public {
        _measure(IEVault(d.hubs[1]), _listMany(500, 0), "500", false);
    }

    /// @dev Separate test: listing 500 assets plus the account set-up exhausts forge's per-test gas budget before
    /// the (51M gas) vault lens call.
    function test_scale_500_vaultLens() public {
        IEVault hub = IEVault(d.hubs[1]);
        address[] memory tokens = _listMany(500, 0);
        _goLiveChunked(tokens, 50e18);
        uint256 g = gasleft();
        (bool ok,) = Arbitrum.VAULT_LENS.staticcall(abi.encodeWithSignature("getVaultInfoFull(address)", address(hub)));
        uint256 used = g - gasleft();
        console.log("VaultLens.getVaultInfoFull 500", used, ok ? "ok" : "REVERTED");
        assertTrue(ok);
        // Finding: above the 50M default eth_call gas cap of many nodes; frontends must not rely on it at 500.
        assertGt(used, 40_000_000);
    }

    function _listMany(uint256 n, uint256 offset) internal returns (address[] memory tokens) {
        AssetConfig[] memory a = new AssetConfig[](n);
        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            MockERC20 t = new MockERC20("S", "S", 18);
            t.mint(deployer, 1e18);
            tokens[i] = address(t);
            a[i] = AssetConfig(
                string.concat("S", vm.toString(offset + i)), address(t), Mechanism.Multiplier, 1, 1, 1e18, 1_000_000e18
            );
        }
        _listViaScripts(a);
    }

    function _goLiveChunked(address[] memory tokens, uint128 price) internal {
        for (uint256 s; s < tokens.length; s += 250) {
            uint256 len = tokens.length - s < 250 ? tokens.length - s : 250;
            address[] memory c = new address[](len);
            for (uint256 k; k < len; ++k) {
                c[k] = tokens[s + k];
            }
            _goLive(c, price);
        }
    }

    function _measure(IEVault hub, address[] memory tokens, string memory label, bool vaultLens) internal {
        _goLiveChunked(tokens, 50e18); // keep every price fresh after the listing's timelock wait
        console.log(string.concat("collaterals in hub (", label, ")"), hub.LTVList().length);

        // An account at EVC's 10-collateral limit: borrow (account + vault status checks) and the account lens.
        address whale = makeAddr(string.concat("whale", label));
        for (uint256 i; i < 10; ++i) {
            address token = tokens[i * (tokens.length / 10)];
            IEVault escrow = IEVault(IPoppieRiskSteward(d.steward).assetInfo(token).escrow);
            MockERC20(token).mint(whale, 10e18);
            vm.startPrank(whale);
            IERC20(token).approve(address(escrow), 10e18);
            escrow.deposit(10e18, whale);
            IEVC(Arbitrum.EVC).enableCollateral(whale, address(escrow));
            vm.stopPrank();
        }
        vm.prank(whale);
        IEVC(Arbitrum.EVC).enableController(whale, address(hub));
        uint256 g = gasleft();
        _borrow(hub, whale, 1_200e6); // 10 x 10 x 50 x 25% = 1,250
        uint256 borrowGas = g - gasleft();
        console.log(string.concat("borrow batch, 10 collaterals, ", label), borrowGas);
        assertLt(borrowGas, BLOCK_GAS);

        g = gasleft();
        hub.accountLiquidity(whale, false);
        console.log(string.concat("accountLiquidity ", label), g - gasleft());

        g = gasleft();
        (bool ok,) = Arbitrum.ACCOUNT_LENS
            .staticcall(abi.encodeWithSignature("getAccountInfo(address,address)", whale, address(hub)));
        console.log(string.concat("AccountLens.getAccountInfo ", label), g - gasleft(), ok ? "ok" : "REVERTED");

        g = gasleft();
        hub.LTVList();
        console.log(string.concat("LTVList() ", label), g - gasleft());

        if (!vaultLens) return;
        // Last: the most expensive view.
        g = gasleft();
        (ok,) = Arbitrum.VAULT_LENS.staticcall(abi.encodeWithSignature("getVaultInfoFull(address)", address(hub)));
        console.log(string.concat("VaultLens.getVaultInfoFull ", label), g - gasleft(), ok ? "ok" : "REVERTED");
    }
}
