// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/console.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {ProtocolConfig} from "evk/ProtocolConfig/ProtocolConfig.sol";
import {SequenceRegistry} from "evk/SequenceRegistry/SequenceRegistry.sol";
import {Base} from "evk/EVault/shared/Base.sol";
import {Dispatch} from "evk/EVault/Dispatch.sol";
import {EVault} from "evk/EVault/EVault.sol";
import {Initialize} from "evk/EVault/modules/Initialize.sol";
import {Token} from "evk/EVault/modules/Token.sol";
import {Vault} from "evk/EVault/modules/Vault.sol";
import {Borrowing} from "evk/EVault/modules/Borrowing.sol";
import {Liquidation} from "evk/EVault/modules/Liquidation.sol";
import {RiskManager} from "evk/EVault/modules/RiskManager.sol";
import {BalanceForwarder} from "evk/EVault/modules/BalanceForwarder.sol";
import {Governance} from "evk/EVault/modules/Governance.sol";

import {Deploy} from "../Deploy.s.sol";
import {BuildListingBatch} from "../BuildListingBatch.s.sol";
import {ConfigCheck} from "../ConfigCheck.s.sol";
import {ScriptBase} from "../lib/ScriptBase.sol";
import {DeployConfig, Deployment, AssetConfig, Mechanism, ListedAsset, SafeTx} from "../lib/Types.sol";

import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockRebasingToken} from "../../test/mocks/MockRebasingToken.sol";
import {MockDividendToken} from "../../test/mocks/MockDividendToken.sol";
import {MockPriceAdapter} from "../../test/mocks/MockPriceAdapter.sol";

/// @title LocalRehearsal
/// @notice End-to-end rehearsal for a local anvil node or any chain without Euler: deploys a local Euler core (EVC,
/// EVK factory and implementation), mock USDC and a mock USDC/USD oracle, then runs `Deploy`, a listing of `n` mock
/// assets (stage 0 approvals through the timelock, stage 1, stage 2 Safe batches executed as the Safes) and
/// `ConfigCheck` before and after. Run as a simulation, never with `--broadcast`:
/// `forge script script/local/LocalRehearsal.s.sol --sig "run(uint256)" 100 --rpc-url http://127.0.0.1:8545`
contract LocalRehearsal is ScriptBase {
    function run(uint256 n) external {
        address deployer = msg.sender;
        DeployConfig memory cfg = _localCore(deployer);
        Deploy deployScript = new Deploy();
        BuildListingBatch batchScript = new BuildListingBatch();
        ConfigCheck check = new ConfigCheck();

        Deployment memory d = deployScript.deploy(cfg, deployer);
        _requireClean(check.checkDeployment(cfg, d), "deployment");

        AssetConfig[] memory assets = _mockAssets(n, deployer, address(MockERC20(cfg.usdc)));
        (SafeTx[] memory schedule, SafeTx[] memory execute) =
            batchScript.approvalTxs(d, assets, cfg.timelockDelay, keccak256("local"));
        _exec(cfg.msAdmin, schedule);
        vm.warp(block.timestamp + cfg.timelockDelay);
        _exec(cfg.msAdmin, execute);

        ListedAsset[] memory listed = batchScript.stage1(d, assets, deployer);
        SafeTx[][] memory batches = batchScript.stage2(d, assets, listed);
        for (uint256 b; b < batches.length; ++b) {
            _exec(cfg.msOps, batches[b]);
        }
        console.log("listed assets", n, "in Safe batches", batches.length);

        _requireClean(check.checkAssets(d, assets, listed, true), "assets");
        _requireClean(check.checkDeployment(cfg, d), "deployment after listing");
        console.log("LocalRehearsal: ConfigCheck reports no diff");
    }

    function _localCore(address deployer) internal returns (DeployConfig memory cfg) {
        vm.startBroadcast(deployer);
        EthereumVaultConnector evc = new EthereumVaultConnector();
        GenericFactory factory = new GenericFactory(deployer);
        Base.Integrations memory integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(new ProtocolConfig(deployer, deployer)),
            sequenceRegistry: address(new SequenceRegistry()),
            balanceTracker: address(0),
            permit2: address(0)
        });
        Dispatch.DeployedModules memory modules = Dispatch.DeployedModules({
            initialize: address(new Initialize(integrations)),
            token: address(new Token(integrations)),
            vault: address(new Vault(integrations)),
            borrowing: address(new Borrowing(integrations)),
            liquidation: address(new Liquidation(integrations)),
            riskManager: address(new RiskManager(integrations)),
            balanceForwarder: address(new BalanceForwarder(integrations)),
            governance: address(new Governance(integrations))
        });
        factory.setImplementation(address(new EVault(integrations, modules)));
        MockERC20 usdc = new MockERC20("Mock USDC", "USDC", 6);
        MockPriceAdapter usdcOracle = new MockPriceAdapter();
        usdcOracle.setPrice(address(usdc), 1e18);
        vm.stopBroadcast();

        DeployConfig memory ex = loadDeployConfig("config/deploy.example.json");
        cfg = ex;
        cfg.evc = address(evc);
        cfg.eVaultFactory = address(factory);
        cfg.usdc = address(usdc);
        cfg.usdcUsdOracle = address(usdcOracle);
        cfg.kinkIrmFactory = address(0);
        cfg.eulerEarnFactory = address(0);
    }

    function _mockAssets(uint256 n, address deployer, address usdc) internal returns (AssetConfig[] memory a) {
        a = new AssetConfig[](n);
        vm.startBroadcast(deployer);
        for (uint256 i; i < n; ++i) {
            Mechanism m = Mechanism(i % 3);
            address token;
            if (m == Mechanism.Multiplier) token = address(new MockERC20("M", "M", 18));
            else if (m == Mechanism.BalanceChanging) token = address(new MockRebasingToken("R", "R", 18));
            else token = address(new MockDividendToken("D", "D", 18, MockERC20(usdc)));
            MockERC20(token).mint(deployer, m == Mechanism.Multiplier ? 1e18 : 2e18);
            uint8 rc = i < n / 5 ? 0 : uint8(1 + i % 3);
            a[i] = AssetConfig(string.concat("L", vm.toString(i)), token, m, rc, rc, 1e18, 1_000_000e18);
        }
        vm.stopBroadcast();
    }

    function _exec(address safe, SafeTx[] memory txs) internal {
        vm.startPrank(safe);
        for (uint256 i; i < txs.length; ++i) {
            (bool ok, bytes memory ret) = txs[i].to.call(txs[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        vm.stopPrank();
    }

    function _requireClean(string[] memory diffs, string memory what) internal pure {
        for (uint256 i; i < diffs.length; ++i) {
            console.log(diffs[i]);
        }
        require(diffs.length == 0, string.concat("ConfigCheck diff: ", what));
    }
}
