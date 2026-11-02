// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

import {PoppieWrapperFactory} from "../src/wrapper/PoppieWrapperFactory.sol";
import {PoppieRouterGovernor} from "../src/governance/PoppieRouterGovernor.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieRiskSteward} from "../src/interfaces/IPoppieRiskSteward.sol";
import {IPoppieRouterGovernor} from "../src/interfaces/IPoppieRouterGovernor.sol";
import {ESCROW_HOOKED_OPS} from "../src/hooks/HookOps.sol";

import {ScriptBase} from "./lib/ScriptBase.sol";
import {Deployment, AssetConfig, ListedAsset, SafeTx} from "./lib/Types.sol";

/// @title BuildListingBatch
/// @notice Listing tooling for `config/assets.json` (V2_PLAN section 7, CONTRACT_SPEC section 2 "Listing flow").
/// Three steps, kept separable (POP-19 may merge stages 1 and 2 into one Safe batch later):
///
/// - **Stage 0, MS_ADMIN Safe -> timelock:** `routerGovernor.setApprovedToken(token, true)` for every token, as a
///   `scheduleBatch` and, after the delay, an `executeBatch` (two Transaction Builder files). The approved-token
///   list is timelocked, so this precedes stage 2 by at least 48h.
/// - **Stage 1, deployer key (simulation only here):** per asset, the wrapper for `balance-changing` and
///   `distributing` tokens (factory seed), then the escrow vault: create (non-upgradeable, no oracle, no unit of
///   account), seed deposit, hook config, governance to the Poppie Governor. Writes the created addresses.
/// - **Stage 2, MS_OPS Safe:** per batch, `oracle.listAssets` -> `addWrapper` (wrapped only) -> `addRoute` ->
///   `addResolvedVault` -> `steward.setCapCeiling` -> `steward.list`. Assets are packed into batches whose estimated
///   gas stays under `GAS_BUDGET`, since a Transaction Builder batch executes as one MultiSend transaction.
///
/// Output is deterministic (no timestamps), so the same inputs give byte-identical files.
///
/// @dev The deployer funds seeds (Q1, flagged POP-19): a wrapped asset needs 2 x `seedAmount` of the token (the
/// wrapper's own seed, then wrapper shares for the escrow seed). Escrow seed shares stay with the deployer key.
/// Simulation, anvil or fork only; never `--broadcast` to a live network from an agent (stage 1 on Arbitrum is part
/// of POP-18, human only).
contract BuildListingBatch is ScriptBase {
    /// @dev Per Safe batch. Leaves headroom under Arbitrum's 32M block gas limit for estimate error.
    uint256 public constant GAS_BUDGET = 20_000_000;

    // Per-asset gas estimates for stage 2 (measured on the local EVK, rounded up; see test/scripts).
    uint256 internal constant G_ORACLE_LIST = 70_000;
    uint256 internal constant G_ADD_WRAPPER = 90_000;
    uint256 internal constant G_ADD_ROUTE = 60_000;
    uint256 internal constant G_ADD_RESOLVED = 120_000;
    uint256 internal constant G_CEILING = 40_000;
    uint256 internal constant G_LIST_LONG_TAIL = 200_000;
    uint256 internal constant G_LIST_BLUE_CHIP_PER_HUB = 100_000;
    uint256 internal constant G_BATCH_BASE = 200_000;

    // -- Entry points ---------------------------------------------------------------------------

    /// @notice `step`: "approvals", "stage1" or "stage2". Files go to `batches/<name>/`. `safe` is the Safe the
    /// Transaction Builder files are for (MS_ADMIN for "approvals", MS_OPS for "stage2"; unused for "stage1").
    function run(
        string memory step,
        string memory name,
        string memory assetsPath,
        string memory deploymentPath,
        address safe
    ) external {
        AssetConfig[] memory assets = loadAssets(assetsPath);
        Deployment memory d = loadDeployment(deploymentPath);
        string memory dir = string.concat("batches/", name, "/");
        bytes32 h = keccak256(bytes(step));
        if (h == keccak256("approvals")) {
            _writeApprovals(d, assets, dir, name, safe);
        } else if (h == keccak256("stage1")) {
            vm.writeFile(string.concat(dir, "1-stage1.json"), listedJson(stage1(d, assets, msg.sender)));
        } else if (h == keccak256("stage2")) {
            _writeStage2(d, assets, dir, name, safe);
        } else {
            revert("BuildListingBatch: step must be approvals | stage1 | stage2");
        }
    }

    function _writeApprovals(
        Deployment memory d,
        AssetConfig[] memory assets,
        string memory dir,
        string memory name,
        address safe
    ) internal {
        uint256 delay = TimelockController(payable(d.timelock)).getMinDelay();
        (SafeTx[] memory s, SafeTx[] memory e) = approvalTxs(d, assets, delay, keccak256(bytes(name)));
        vm.writeFile(string.concat(dir, "0-schedule.json"), safeBatchJson(block.chainid, safe, name, s));
        vm.writeFile(string.concat(dir, "0-execute.json"), safeBatchJson(block.chainid, safe, name, e));
    }

    function _writeStage2(
        Deployment memory d,
        AssetConfig[] memory assets,
        string memory dir,
        string memory name,
        address safe
    ) internal {
        SafeTx[][] memory batches = stage2(d, assets, loadListed(string.concat(dir, "1-stage1.json")));
        for (uint256 i; i < batches.length; ++i) {
            vm.writeFile(
                string.concat(dir, "2-ops-", vm.toString(i), ".json"),
                safeBatchJson(block.chainid, safe, string.concat(name, " #", vm.toString(i)), batches[i])
            );
        }
    }

    // -- Stage 0 --------------------------------------------------------------------------------

    function approvalTxs(Deployment memory d, AssetConfig[] memory assets, uint256 delay, bytes32 salt)
        public
        pure
        returns (SafeTx[] memory schedule, SafeTx[] memory execute)
    {
        uint256 n = assets.length;
        address[] memory targets = new address[](n);
        uint256[] memory values = new uint256[](n);
        bytes[] memory payloads = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            targets[i] = d.routerGovernor;
            payloads[i] = abi.encodeCall(IPoppieRouterGovernor.setApprovedToken, (assets[i].token, true));
        }
        schedule = new SafeTx[](1);
        schedule[0] = SafeTx(
            d.timelock,
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, delay))
        );
        execute = new SafeTx[](1);
        execute[0] = SafeTx(
            d.timelock, abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt))
        );
    }

    // -- Stage 1 --------------------------------------------------------------------------------

    /// @notice Create wrappers and escrow vaults as `deployer`, who must hold the seed tokens.
    function stage1(Deployment memory d, AssetConfig[] memory assets, address deployer)
        public
        returns (ListedAsset[] memory listed)
    {
        listed = new ListedAsset[](assets.length);
        address vaultFactory = PoppieRouterGovernor(d.routerGovernor).vaultFactory();
        vm.startBroadcast(deployer);
        for (uint256 i; i < assets.length; ++i) {
            listed[i] = _stage1One(d, assets[i], vaultFactory, deployer);
        }
        vm.stopBroadcast();
    }

    function _stage1One(Deployment memory d, AssetConfig memory a, address vaultFactory, address deployer)
        internal
        returns (ListedAsset memory l)
    {
        l.token = a.token;
        address held = a.token;
        uint256 seed = a.seedAmount;
        if (isWrapped(a.mechanism)) {
            IERC20(a.token).approve(d.wrapperFactory, a.seedAmount);
            l.wrapper = PoppieWrapperFactory(d.wrapperFactory).createWrapper(a.token, a.seedAmount);
            IERC20(a.token).approve(l.wrapper, a.seedAmount);
            seed = IERC4626(l.wrapper).deposit(a.seedAmount, deployer);
            held = l.wrapper;
        }
        IEVault escrow = IEVault(
            GenericFactory(vaultFactory).createProxy(address(0), false, abi.encodePacked(held, address(0), address(0)))
        );
        l.escrow = address(escrow);
        // A fresh EVK vault hooks every operation with no target (all disabled): open it for the seed deposit.
        escrow.setHookConfig(address(0), 0);
        IERC20(held).approve(l.escrow, seed);
        escrow.deposit(seed, deployer);
        escrow.setHookConfig(d.escrowHook, ESCROW_HOOKED_OPS);
        escrow.setGovernorAdmin(d.governor);
    }

    // -- Stage 2 --------------------------------------------------------------------------------

    /// @notice The MS_OPS Safe batches, packed under `GAS_BUDGET`. Deterministic for a given input and chain state.
    function stage2(Deployment memory d, AssetConfig[] memory assets, ListedAsset[] memory listed)
        public
        view
        returns (SafeTx[][] memory batches)
    {
        require(assets.length == listed.length, "stage2: stage-1 output does not match the asset list");
        uint256 nHubs = d.hubs.length;
        // Pass 1: batch boundaries.
        uint256[] memory ends = new uint256[](assets.length);
        uint256 nBatches;
        uint256 gas = G_BATCH_BASE;
        for (uint256 i; i < assets.length; ++i) {
            require(listed[i].token == assets[i].token, "stage2: stage-1 order mismatch");
            uint256 g = estimateGas(assets[i], nHubs);
            if (gas + g > GAS_BUDGET && gas != G_BATCH_BASE) {
                ends[nBatches++] = i;
                gas = G_BATCH_BASE;
            }
            gas += g;
        }
        ends[nBatches++] = assets.length;

        batches = new SafeTx[][](nBatches);
        uint256 start;
        for (uint256 b; b < nBatches; ++b) {
            batches[b] = _batch(d, assets, listed, start, ends[b]);
            start = ends[b];
        }
    }

    function estimateGas(AssetConfig memory a, uint256 nHubs) public pure returns (uint256 g) {
        g = G_ORACLE_LIST + G_ADD_ROUTE + G_ADD_RESOLVED + G_CEILING;
        if (isWrapped(a.mechanism)) g += G_ADD_WRAPPER;
        g += a.riskClass == 0 ? G_LIST_BLUE_CHIP_PER_HUB * nHubs : G_LIST_LONG_TAIL;
    }

    struct BatchArrays {
        address[] tokens;
        IPoppieEulerOracle.PriceClass[] classes;
        IPoppieRiskSteward.CapCeilingChange[] ceilings;
        IPoppieRiskSteward.Listing[] listings;
    }

    function _batch(
        Deployment memory d,
        AssetConfig[] memory assets,
        ListedAsset[] memory listed,
        uint256 start,
        uint256 end
    ) internal view returns (SafeTx[] memory txs) {
        BatchArrays memory a = _arrays(d, assets, listed, start, end);
        uint256 nWrapped;
        for (uint256 i = start; i < end; ++i) {
            if (listed[i].wrapper != address(0)) ++nWrapped;
        }
        txs = new SafeTx[](1 + nWrapped + 2 * (end - start) + 2);
        uint256 k;
        txs[k++] = SafeTx(d.oracle, abi.encodeCall(IPoppieEulerOracle.listAssets, (a.tokens, a.classes)));
        for (uint256 i = start; i < end; ++i) {
            if (listed[i].wrapper != address(0)) {
                txs[k++] =
                    SafeTx(d.routerGovernor, abi.encodeCall(IPoppieRouterGovernor.addWrapper, (listed[i].wrapper)));
            }
            txs[k++] = SafeTx(d.routerGovernor, abi.encodeCall(IPoppieRouterGovernor.addRoute, (listed[i].token)));
            txs[k++] =
                SafeTx(d.routerGovernor, abi.encodeCall(IPoppieRouterGovernor.addResolvedVault, (listed[i].escrow)));
        }
        txs[k++] = SafeTx(d.steward, abi.encodeCall(IPoppieRiskSteward.setCapCeiling, (a.ceilings)));
        txs[k++] = SafeTx(d.steward, abi.encodeCall(IPoppieRiskSteward.list, (a.listings)));
    }

    function _arrays(
        Deployment memory d,
        AssetConfig[] memory assets,
        ListedAsset[] memory listed,
        uint256 start,
        uint256 end
    ) internal view returns (BatchArrays memory a) {
        uint256 n = end - start;
        a.tokens = new address[](n);
        a.classes = new IPoppieEulerOracle.PriceClass[](n);
        a.ceilings = new IPoppieRiskSteward.CapCeilingChange[](n);
        a.listings = new IPoppieRiskSteward.Listing[](n);
        for (uint256 i; i < n; ++i) {
            AssetConfig memory c = assets[start + i];
            ListedAsset memory l = listed[start + i];
            a.tokens[i] = c.token;
            a.classes[i] = IPoppieEulerOracle.PriceClass(c.riskClass);
            a.ceilings[i] = IPoppieRiskSteward.CapCeilingChange(l.escrow, encodeCap(_ceilingInEscrowUnits(c, l)), 1);
            a.listings[i] = IPoppieRiskSteward.Listing(
                c.token, l.escrow, d.hubs[c.hubIndex], IPoppieRiskSteward.RiskClass(c.riskClass)
            );
        }
    }

    /// @dev The ceiling in `config/assets.json` is in token units; a wrapped escrow holds wrapper shares, so it is
    /// converted at the wrapper's current rate.
    function _ceilingInEscrowUnits(AssetConfig memory a, ListedAsset memory l) internal view returns (uint256) {
        if (l.wrapper == address(0)) return a.supplyCapCeiling;
        return IERC4626(l.wrapper).convertToShares(a.supplyCapCeiling);
    }

    // -- Stage-1 records ------------------------------------------------------------------------

    function listedJson(ListedAsset[] memory listed) public pure returns (string memory out) {
        out = '{"listed":[';
        for (uint256 i; i < listed.length; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                '{"token":"',
                vm.toString(listed[i].token),
                '","wrapper":"',
                vm.toString(listed[i].wrapper),
                '","escrow":"',
                vm.toString(listed[i].escrow),
                '"}'
            );
        }
        out = string.concat(out, "]}");
    }
}
