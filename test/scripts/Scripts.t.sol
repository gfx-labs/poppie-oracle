// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IEVault, IGovernance} from "evk/EVault/IEVault.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {BuildListingBatch} from "../../script/BuildListingBatch.s.sol";
import {ConfigCheck} from "../../script/ConfigCheck.s.sol";
import {
    DeployConfig,
    HubParams,
    EarnParams,
    Deployment,
    AssetConfig,
    Mechanism,
    ListedAsset,
    SafeTx
} from "../../script/lib/Types.sol";
import {PoppieRiskSteward} from "../../src/steward/PoppieRiskSteward.sol";
import {MS_OPS} from "../../src/access/Roles.sol";

import {PoppieTestBase} from "../harness/PoppieTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebasingToken} from "../mocks/MockRebasingToken.sol";
import {MockDividendToken} from "../mocks/MockDividendToken.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";

/// @notice POP-14 done-when, on the local EVK: a full `Deploy` plus a 100-asset listing (stage 0 timelock approvals,
/// stage 1 deployer, stage 2 MS_OPS Safe batches executed transaction by transaction) with `ConfigCheck` clean before
/// and after; the batch generator is byte-for-byte reproducible; `distributing` takes the wrapper path; ConfigCheck
/// catches a zero fee receiver and a role left with the deployer. Nothing is broadcast anywhere.
contract ScriptsTest is PoppieTestBase {
    uint256 internal constant N_ASSETS = 100;
    uint256 internal constant BLOCK_GAS = 32_000_000;

    Deploy internal deployScript;
    BuildListingBatch internal batchScript;
    ConfigCheck internal checkScript;

    address internal deployer = makeAddr("deployer");
    DeployConfig internal cfg;
    Deployment internal d;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        deployScript = new Deploy();
        batchScript = new BuildListingBatch();
        checkScript = new ConfigCheck();

        MockPriceAdapter usdcOracle = new MockPriceAdapter();
        usdcOracle.setPrice(address(usdc), 1e18);
        DeployConfig memory c = _config(address(usdcOracle));
        _store(c);
        d = deployScript.deploy(c, deployer);
    }

    // -- Config ---------------------------------------------------------------------------------

    function _config(address usdcOracle) internal returns (DeployConfig memory c) {
        c.evc = address(evc);
        c.eVaultFactory = address(factory);
        c.usdc = address(usdc);
        c.usdcUsdOracle = usdcOracle;
        c.msAdmin = makeAddr("msAdmin");
        c.msOps = makeAddr("msOps");
        c.reserveSafe = makeAddr("reserveSafe");
        c.kPrice = makeAddr("kPrice");
        c.kConfirm = makeAddr("kConfirm");
        c.kTighten = makeAddr("kTighten");
        c.kGuard = makeAddr("kGuard");
        c.kAlloc = makeAddr("kAlloc");
        c.timelockDelay = 48 hours;
        // Reuse the example's hub parameters (fees, discounts, IRMs, caps), with a real fee receiver.
        DeployConfig memory ex = deployScript.loadDeployConfig("config/deploy.example.json");
        c.hubs = ex.hubs;
        for (uint256 i; i < c.hubs.length; ++i) {
            c.hubs[i].feeReceiver = makeAddr("feeReceiver");
        }
        c.earns = ex.earns; // ignored: no Earn factory locally
    }

    /// @dev Copy into storage (memory struct with nested dynamic arrays).
    function _store(DeployConfig memory c) internal {
        cfg.evc = c.evc;
        cfg.eVaultFactory = c.eVaultFactory;
        cfg.usdc = c.usdc;
        cfg.usdcUsdOracle = c.usdcUsdOracle;
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
    }

    function _cfg() internal view returns (DeployConfig memory) {
        return cfg;
    }

    /// @dev 100 assets: 20 blue chips, the rest spread over M1-M3; mechanisms rotate (multiplier, balance-changing,
    /// distributing). The deployer is funded with the seeds (twice for wrapped assets).
    function _assets(uint256 n) internal returns (AssetConfig[] memory a) {
        a = new AssetConfig[](n);
        for (uint256 i; i < n; ++i) {
            Mechanism m = Mechanism(i % 3);
            address token;
            if (m == Mechanism.Multiplier) token = address(new MockERC20("M", "M", 18));
            else if (m == Mechanism.BalanceChanging) token = address(new MockRebasingToken("R", "R", 18));
            else token = address(new MockDividendToken("D", "D", 18, usdc));
            uint8 rc = i < 20 ? 0 : uint8(1 + i % 3);
            a[i] = AssetConfig({
                symbol: string.concat("A", vm.toString(i)),
                token: token,
                mechanism: m,
                riskClass: rc,
                hubIndex: rc,
                seedAmount: 1e18,
                supplyCapCeiling: 1_000_000e18
            });
            MockERC20(token).mint(deployer, m == Mechanism.Multiplier ? 1e18 : 2e18);
        }
    }

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

    function _assertNoDiff(string[] memory diffs) internal pure {
        for (uint256 i; i < diffs.length; ++i) {
            console.log(diffs[i]);
        }
        assertEq(diffs.length, 0, "ConfigCheck diff");
    }

    function _list(AssetConfig[] memory assets) internal returns (ListedAsset[] memory listed) {
        (SafeTx[] memory schedule, SafeTx[] memory execute) =
            batchScript.approvalTxs(d, assets, cfg.timelockDelay, keccak256("batch-1"));
        _exec(cfg.msAdmin, schedule);
        vm.warp(block.timestamp + cfg.timelockDelay);
        _exec(cfg.msAdmin, execute);

        listed = batchScript.stage1(d, assets, deployer);
        SafeTx[][] memory batches = batchScript.stage2(d, assets, listed);
        for (uint256 b; b < batches.length; ++b) {
            uint256 g = _exec(cfg.msOps, batches[b]);
            console.log("stage-2 batch gas", b, g);
            assertLt(g, BLOCK_GAS, "Safe batch over the block gas limit");
        }
    }

    // -- Tests ----------------------------------------------------------------------------------

    function test_deployThenConfigCheckClean() public {
        _assertNoDiff(checkScript.checkDeployment(_cfg(), d));
        assertEq(d.hubs.length, 4);
        assertEq(d.earns.length, 0);
    }

    function test_deployHandsEverythingToTimelock() public view {
        address[7] memory c =
            [d.oracle, d.hubHook, d.feeRouter, d.escrowHook, d.wrapperFactory, d.routerGovernor, d.steward];
        for (uint256 i; i < 7; ++i) {
            assertTrue(IAccessControl(c[i]).hasRole(0x00, d.timelock));
            assertFalse(IAccessControl(c[i]).hasRole(0x00, deployer));
        }
        assertEq(IEVault(d.hubs[0]).feeReceiver(), cfg.hubs[0].feeReceiver);
    }

    function test_fullListing100AssetsEndToEnd() public {
        AssetConfig[] memory assets = _assets(N_ASSETS);
        _assertNoDiff(checkScript.checkDeployment(_cfg(), d)); // before
        ListedAsset[] memory listed = _list(assets);
        _assertNoDiff(checkScript.checkAssets(d, assets, listed, true)); // after
        _assertNoDiff(checkScript.checkDeployment(_cfg(), d));

        uint256 wrapped;
        for (uint256 i; i < N_ASSETS; ++i) {
            if (listed[i].wrapper != address(0)) ++wrapped;
            // distributing takes the wrapper path, like balance-changing.
            if (assets[i].mechanism == Mechanism.Distributing) assertTrue(listed[i].wrapper != address(0));
            if (assets[i].mechanism == Mechanism.Multiplier) assertEq(listed[i].wrapper, address(0));
        }
        assertEq(wrapped, 66);
        assertEq(PoppieRiskSteward(d.steward).assetInfo(assets[50].token).escrow, listed[50].escrow);
    }

    function test_batchGeneratorIsReproducible() public {
        AssetConfig[] memory assets = _assets(30);
        (SafeTx[] memory schedule, SafeTx[] memory execute) =
            batchScript.approvalTxs(d, assets, cfg.timelockDelay, keccak256("batch-1"));
        _exec(cfg.msAdmin, schedule);
        vm.warp(block.timestamp + cfg.timelockDelay);
        _exec(cfg.msAdmin, execute);
        ListedAsset[] memory listed = batchScript.stage1(d, assets, deployer);

        string memory first = _render(batchScript.stage2(d, assets, listed));
        string memory second = _render(batchScript.stage2(d, assets, listed));
        assertEq(keccak256(bytes(first)), keccak256(bytes(second)));

        // The Transaction Builder JSON parses, and round-trips the first transaction.
        SafeTx[][] memory b = batchScript.stage2(d, assets, listed);
        string memory j = batchScript.safeBatchJson(block.chainid, cfg.msOps, "t", b[0]);
        assertEq(vm.parseJsonAddress(j, ".transactions[0].to"), b[0][0].to);
        assertEq(vm.parseJsonBytes(j, ".transactions[0].data"), b[0][0].data);
        assertEq(vm.parseJsonUint(j, ".createdAt"), 0);
    }

    function _render(SafeTx[][] memory batches) internal view returns (string memory out) {
        for (uint256 i; i < batches.length; ++i) {
            out = string.concat(out, batchScript.safeBatchJson(block.chainid, cfg.msOps, "x", batches[i]));
        }
    }

    function test_stage2PacksUnderBudget() public {
        AssetConfig[] memory assets = _assets(N_ASSETS);
        uint256 total;
        for (uint256 i; i < N_ASSETS; ++i) {
            total += batchScript.estimateGas(assets[i], 4);
        }
        // Several Safe batches are needed for 100 assets.
        assertGt(total, batchScript.GAS_BUDGET());
    }

    function test_configCheckFlagsZeroFeeReceiver() public {
        // The timelock (Governor wildcard) zeroes a hub's fee receiver.
        vm.prank(d.timelock);
        (bool ok,) =
            d.governor.call(abi.encodePacked(abi.encodeCall(IGovernance.setFeeReceiver, (address(0))), d.hubs[2]));
        assertTrue(ok);
        string[] memory diffs = checkScript.checkDeployment(_cfg(), d);
        bool found;
        for (uint256 i; i < diffs.length; ++i) {
            if (_contains(diffs[i], "ZERO FEE RECEIVER")) found = true;
        }
        assertTrue(found);
    }

    function test_configCheckFlagsDeployerRole() public {
        vm.prank(d.timelock);
        IAccessControl(d.oracle).grantRole(MS_OPS, deployer);
        string[] memory diffs = checkScript.checkDeployment(_cfg(), d);
        assertEq(diffs.length, 1);
        assertTrue(_contains(diffs[0], "deployer still holds role"));
    }

    function test_deployRejectsZeroFeeReceiverAndShortTimelock() public {
        DeployConfig memory c = _cfg();
        c.hubs[1].feeReceiver = address(0);
        vm.expectRevert(bytes("Deploy: zero fee receiver"));
        deployScript.deploy(c, deployer);
        c = _cfg();
        c.timelockDelay = 47 hours;
        vm.expectRevert(bytes("Deploy: timelock delay < 48h"));
        deployScript.deploy(c, deployer);
    }

    function test_exampleConfigsParse() public view {
        DeployConfig memory c = deployScript.loadDeployConfig("config/deploy.example.json");
        assertEq(c.hubs.length, 4);
        assertEq(c.hubs[3].originationFeeBps, 35);
        assertEq(c.hubs[0].maxLiquidationDiscount, 800);
        assertEq(c.timelockDelay, 48 hours);
        assertEq(c.earns.length, 2);
        assertEq(c.earns[1].hubIndexes.length, 4);

        AssetConfig[] memory a = deployScript.loadAssets("config/assets.example.json");
        assertEq(a.length, 5);
        assertEq(uint8(a[1].mechanism), uint8(Mechanism.BalanceChanging));
        assertEq(uint8(a[2].mechanism), uint8(Mechanism.Distributing));
        assertEq(a[2].riskClass, 1);
        assertEq(a[3].seedAmount, 1e6);
    }

    function test_recordsRoundTripThroughFiles() public {
        string memory path = "deployments/roundtrip-test.json";
        vm.writeJson(deployScript.deploymentJson(d), path);
        Deployment memory back = deployScript.loadDeployment(path);
        vm.removeFile(path);
        assertEq(back.steward, d.steward);
        assertEq(back.hubs.length, 4);
        assertEq(back.hubs[3], d.hubs[3]);
        assertEq(back.earns.length, 0);

        ListedAsset[] memory l = new ListedAsset[](2);
        l[0] = ListedAsset(address(1), address(0), address(2));
        l[1] = ListedAsset(address(3), address(4), address(5));
        string memory lp = "batches/roundtrip-test.json";
        vm.writeFile(lp, batchScript.listedJson(l));
        ListedAsset[] memory lb = batchScript.loadListed(lp);
        vm.removeFile(lp);
        assertEq(lb.length, 2);
        assertEq(lb[1].wrapper, address(4));
        assertEq(lb[0].wrapper, address(0));
    }

    function _contains(string memory s, string memory sub) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(sub);
        if (b.length > a.length) return false;
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool m = true;
            for (uint256 k; k < b.length; ++k) {
                if (a[i + k] != b[k]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }

    // Unused import guard.
    function _unused() internal pure returns (bytes4, bytes4) {
        return (TimelockController.getMinDelay.selector, IERC4626.asset.selector);
    }
}
