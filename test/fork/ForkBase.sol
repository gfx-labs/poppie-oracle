// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVault, IBorrowing, IRiskManager, ILiquidation} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {BuildListingBatch} from "../../script/BuildListingBatch.s.sol";
import {ConfigCheck} from "../../script/ConfigCheck.s.sol";
import {DeployConfig, Deployment, AssetConfig, Mechanism, ListedAsset, SafeTx} from "../../script/lib/Types.sol";
import {PoppieFeeRouter} from "../../src/fee/PoppieFeeRouter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";

import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";

/// @notice Canonical Euler addresses on Arbitrum (chain 42161), from euler-xyz/euler-interfaces
/// `addresses/42161/{Core,Periphery,Lens}Addresses.json`, each checked on chain (code present; factory implementation
/// and Earn perspective as listed). Safe v1.4.1 and Zodiac Roles v2 are the canonical singleton deployments
/// (Safe singleton reports VERSION 1.4.1; Roles ABI fetched from the verified source).
library Arbitrum {
    address internal constant EVC = 0x6302ef0F34100CDDFb5489fbcB6eE1AA95CD1066;
    address internal constant EVAULT_FACTORY = 0x78Df1CF5bf06a7f27f2ACc580B934238C1b80D50;
    address internal constant EVAULT_IMPLEMENTATION = 0x832fF4011A3164ea76ceA06A313EE0B6CD72ba96;
    address internal constant PROTOCOL_CONFIG = 0x06c1Ab0A1672E8FC7F7D10BD7B869B4116D18a2c;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant EULER_EARN_FACTORY = 0xB9B5d62B9fE9E1B505466e75817aB178A1D2ec9d;
    address internal constant EVK_FACTORY_PERSPECTIVE = 0x03a931446F5A7e7ec1D850D8eaF95Ab68Ad9089C;
    address internal constant KINK_IRM_FACTORY = 0xE055ea126c7704fFCf3Bd8a8F46aC93A6965560E;
    address internal constant ACCOUNT_LENS = 0x5E3AedDd85E95d8B3f6A903B2941CED2Cf7715E0;
    address internal constant VAULT_LENS = 0xef639A4BD79Bf08523ADa43E6aD1b1222fBEC288;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC

    address internal constant SAFE_SINGLETON_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant ROLES_V2_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;
}

/// @notice Arbitrum fork, read-only against the live chain: every write lands in the local fork. Skips cleanly when
/// the `arbitrum` RPC alias cannot be resolved (no key configured). Deploys Poppie with the real scripts.
/// @dev The RPC alias is resolved by foundry from `foundry.toml`; this code never sees the URL or key.
abstract contract ForkBase is Test {
    /// @dev Pinned for reproducibility and RPC caching (free-tier RPC: run fork suites one at a time).
    uint256 internal constant FORK_BLOCK = 520_600_000;
    uint256 internal constant BLOCK_GAS = 32_000_000;
    address internal constant USD = address(840);

    Deploy internal deployScript;
    BuildListingBatch internal batchScript;
    ConfigCheck internal checkScript;
    DeployConfig internal cfg;
    Deployment internal d;
    MockPriceAdapter internal usdcOracle;

    address internal deployer = makeAddr("deployer");
    address internal lender = makeAddr("lender");
    address internal liquidator = makeAddr("liquidator");

    /// @return ok False when no fork is available (the caller then skips).
    function _fork() internal returns (bool ok) {
        if (block.chainid == 42161) return true;
        try vm.createSelectFork("arbitrum", FORK_BLOCK) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Fork, then deploy the stack with `Deploy.s.sol` against canonical Euler (Earn factory and kink IRM
    /// factory included). The USDC/USD oracle is a stand-in: no canonical fixed-rate adapter is configured yet.
    function _forkAndDeploy() internal returns (bool) {
        if (!_fork()) return false;
        deployScript = new Deploy();
        batchScript = new BuildListingBatch();
        checkScript = new ConfigCheck();
        usdcOracle = new MockPriceAdapter();
        usdcOracle.setPrice(Arbitrum.USDC, 1e18);

        DeployConfig memory ex = deployScript.loadDeployConfig("config/deploy.example.json");
        DeployConfig memory c = ex;
        c.evc = Arbitrum.EVC;
        c.eVaultFactory = Arbitrum.EVAULT_FACTORY;
        c.usdc = Arbitrum.USDC;
        c.usdcUsdOracle = address(usdcOracle);
        c.kinkIrmFactory = Arbitrum.KINK_IRM_FACTORY;
        c.eulerEarnFactory = Arbitrum.EULER_EARN_FACTORY;
        c.msAdmin = makeAddr("msAdmin");
        c.msOps = makeAddr("msOps");
        c.reserveSafe = makeAddr("reserveSafe");
        c.kPrice = makeAddr("kPrice");
        c.kConfirm = makeAddr("kConfirm");
        c.kTighten = makeAddr("kTighten");
        c.kGuard = makeAddr("kGuard");
        c.kAlloc = makeAddr("kAlloc");
        for (uint256 i; i < c.hubs.length; ++i) {
            c.hubs[i].feeReceiver = makeAddr("feeReceiver");
        }
        _store(c);
        d = deployScript.deploy(c, deployer);

        // Lender liquidity in every hub.
        for (uint256 i; i < d.hubs.length; ++i) {
            deal(Arbitrum.USDC, lender, 1_000_000e6);
            vm.startPrank(lender);
            IERC20(Arbitrum.USDC).approve(d.hubs[i], type(uint256).max);
            IEVault(d.hubs[i]).deposit(1_000_000e6, lender);
            vm.stopPrank();
        }
        return true;
    }

    function _store(DeployConfig memory c) internal {
        cfg.evc = c.evc;
        cfg.eVaultFactory = c.eVaultFactory;
        cfg.usdc = c.usdc;
        cfg.usdcUsdOracle = c.usdcUsdOracle;
        cfg.kinkIrmFactory = c.kinkIrmFactory;
        cfg.eulerEarnFactory = c.eulerEarnFactory;
        cfg.msAdmin = c.msAdmin;
        cfg.msOps = c.msOps;
        cfg.reserveSafe = c.reserveSafe;
        cfg.kPrice = c.kPrice;
        cfg.kConfirm = c.kConfirm;
        cfg.kTighten = c.kTighten;
        cfg.kGuard = c.kGuard;
        cfg.kAlloc = c.kAlloc;
        cfg.timelockDelay = c.timelockDelay;
        for (uint256 i; i < c.hubs.length; ++i) {
            cfg.hubs.push(c.hubs[i]);
        }
        for (uint256 i; i < c.earns.length; ++i) {
            cfg.earns.push();
            cfg.earns[i].name = c.earns[i].name;
            cfg.earns[i].symbol = c.earns[i].symbol;
            cfg.earns[i].timelock = c.earns[i].timelock;
            cfg.earns[i].capPerHub = c.earns[i].capPerHub;
            cfg.earns[i].hubIndexes = c.earns[i].hubIndexes;
        }
    }

    function _cfg() internal view returns (DeployConfig memory) {
        return cfg;
    }

    // -- Listing through the scripts ------------------------------------------------------------

    function _exec(address from, SafeTx[] memory txs) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        for (uint256 i; i < txs.length; ++i) {
            vm.prank(from);
            (bool ok, bytes memory ret) = txs[i].to.call(txs[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        gasUsed = g - gasleft();
    }

    /// @dev Stage 0 (timelock approvals), stage 1 (deployer), stage 2 (MS_OPS Safe batches). The deployer must
    /// hold the seeds.
    function _listViaScripts(AssetConfig[] memory assets) internal returns (ListedAsset[] memory listed) {
        (SafeTx[] memory schedule, SafeTx[] memory execute) =
            batchScript.approvalTxs(d, assets, cfg.timelockDelay, keccak256(abi.encode(assets.length, block.number)));
        _exec(cfg.msAdmin, schedule);
        vm.warp(block.timestamp + cfg.timelockDelay);
        _exec(cfg.msAdmin, execute);
        listed = batchScript.stage1(d, assets, deployer);
        SafeTx[][] memory batches = batchScript.stage2(d, assets, listed);
        for (uint256 b; b < batches.length; ++b) {
            vm.roll(block.number + 1);
            assertLt(_exec(cfg.msOps, batches[b]), BLOCK_GAS, "Safe batch gas");
        }
    }

    // -- Oracle ---------------------------------------------------------------------------------

    function _goLive(address[] memory tokens, uint128 price) internal {
        uint128[] memory p = new uint128[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            p[i] = price;
        }
        vm.prank(cfg.kPrice);
        IPoppieEulerOracle(d.oracle).keeperPushPrices(tokens, p);
        vm.prank(cfg.kConfirm);
        IPoppieEulerOracle(d.oracle).confirmBatch(tokens, p);
    }

    function _goLive(address token, uint128 price) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        _goLive(t, price);
    }

    function _push(address token, uint128 price) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        uint128[] memory p = new uint128[](1);
        p[0] = price;
        vm.prank(cfg.kPrice);
        IPoppieEulerOracle(d.oracle).keeperPushPrices(t, p);
    }

    // -- Accounts -------------------------------------------------------------------------------

    function _borrow(IEVault hub, address account, uint256 amount) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(hub),
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(IBorrowing.borrow, (amount, d.feeRouter))
        });
        items[1] = IEVC.BatchItem({
            targetContract: d.feeRouter,
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(PoppieFeeRouter.forward, (address(hub), account))
        });
        vm.prank(account);
        IEVC(Arbitrum.EVC).batch(items);
    }

    function _liquidate(IEVault hub, address violator, address collateral) internal {
        deal(Arbitrum.USDC, liquidator, 10_000_000e6);
        vm.startPrank(liquidator);
        IERC20(Arbitrum.USDC).approve(address(hub), type(uint256).max);
        IEVC(Arbitrum.EVC).enableController(liquidator, address(hub));
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem(
            address(hub),
            liquidator,
            0,
            abi.encodeCall(ILiquidation.liquidate, (violator, collateral, type(uint256).max, 0))
        );
        items[1] = IEVC.BatchItem(
            address(hub), liquidator, 0, abi.encodeCall(IBorrowing.repay, (type(uint256).max, liquidator))
        );
        items[2] = IEVC.BatchItem(address(hub), liquidator, 0, abi.encodeCall(IRiskManager.disableController, ()));
        IEVC(Arbitrum.EVC).batch(items);
        vm.stopPrank();
    }

    function _assertNoDiff(string[] memory diffs) internal pure {
        for (uint256 i; i < diffs.length; ++i) {
            console.log(diffs[i]);
        }
        assertEq(diffs.length, 0, "ConfigCheck diff");
    }
}
