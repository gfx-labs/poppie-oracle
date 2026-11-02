// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {
    DeployConfig,
    HubParams,
    EarnParams,
    Deployment,
    AssetConfig,
    Mechanism,
    ListedAsset,
    SafeTx
} from "./Types.sol";

/// @notice Config loading, deployment records and Safe Transaction Builder output shared by the Poppie scripts.
/// @dev No script in this repo is ever run with `--broadcast` against a live network by an agent (AGENTS.md).
/// Every `run()` here is meant for simulation, a local anvil node or a fork; the live launch is POP-18 (human only).
abstract contract ScriptBase is Script {
    // -- JSON -----------------------------------------------------------------------------------

    /// @dev Length of the JSON array at `path` (0 if absent).
    function countJson(string memory j, string memory path) public view returns (uint256 n) {
        while (vm.keyExistsJson(j, string.concat(path, "[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    function loadListed(string memory path) public view returns (ListedAsset[] memory listed) {
        string memory j = vm.readFile(path);
        uint256 n = countJson(j, ".listed");
        listed = new ListedAsset[](n);
        for (uint256 i; i < n; ++i) {
            string memory p = string.concat(".listed[", vm.toString(i), "]");
            listed[i] = ListedAsset(
                vm.parseJsonAddress(j, string.concat(p, ".token")),
                vm.parseJsonAddress(j, string.concat(p, ".wrapper")),
                vm.parseJsonAddress(j, string.concat(p, ".escrow"))
            );
        }
    }

    // -- AmountCap ------------------------------------------------------------------------------

    /// @dev Largest AmountCap whose resolved amount is <= `amount` (rounds down); never raw 0 (zero -> raw 1).
    function encodeCap(uint256 amount) public pure returns (uint16) {
        if (amount == 0) return 1;
        uint256 m = amount * 100;
        uint256 e;
        while (m > 1023) {
            m /= 10;
            ++e;
        }
        return uint16((m << 6) | e);
    }

    function resolveCap(uint16 raw) public pure returns (uint256) {
        if (raw == 0) return type(uint256).max;
        return 10 ** (raw & 63) * (raw >> 6) / 100;
    }

    // -- Deploy config --------------------------------------------------------------------------

    function loadDeployConfig(string memory path) public view returns (DeployConfig memory c) {
        string memory j = vm.readFile(path);
        c.evc = vm.parseJsonAddress(j, ".evc");
        c.eVaultFactory = vm.parseJsonAddress(j, ".eVaultFactory");
        c.usdc = vm.parseJsonAddress(j, ".usdc");
        c.usdcUsdOracle = vm.parseJsonAddress(j, ".usdcUsdOracle");
        c.kinkIrmFactory = vm.parseJsonAddress(j, ".kinkIrmFactory");
        c.eulerEarnFactory = vm.parseJsonAddress(j, ".eulerEarnFactory");
        c.msAdmin = vm.parseJsonAddress(j, ".roles.msAdmin");
        c.msOps = vm.parseJsonAddress(j, ".roles.msOps");
        c.reserveSafe = vm.parseJsonAddress(j, ".roles.reserveSafe");
        c.kPrice = vm.parseJsonAddress(j, ".roles.kPrice");
        c.kConfirm = vm.parseJsonAddress(j, ".roles.kConfirm");
        c.kTighten = vm.parseJsonAddress(j, ".roles.kTighten");
        c.kGuard = vm.parseJsonAddress(j, ".roles.kGuard");
        c.kAlloc = vm.parseJsonAddress(j, ".roles.kAlloc");
        c.timelockDelay = vm.parseJsonUint(j, ".timelockDelay");

        uint256 nHubs = countJson(j, ".hubs");
        c.hubs = new HubParams[](nHubs);
        for (uint256 i; i < nHubs; ++i) {
            c.hubs[i] = _loadHub(j, string.concat(".hubs[", vm.toString(i), "]"));
        }
        uint256 nEarns = countJson(j, ".earns");
        c.earns = new EarnParams[](nEarns);
        for (uint256 i; i < nEarns; ++i) {
            string memory p = string.concat(".earns[", vm.toString(i), "]");
            c.earns[i].name = vm.parseJsonString(j, string.concat(p, ".name"));
            c.earns[i].symbol = vm.parseJsonString(j, string.concat(p, ".symbol"));
            c.earns[i].timelock = vm.parseJsonUint(j, string.concat(p, ".timelock"));
            c.earns[i].capPerHub = vm.parseJsonUint(j, string.concat(p, ".capPerHub"));
            c.earns[i].hubIndexes = vm.parseJsonUintArray(j, string.concat(p, ".hubIndexes"));
        }
    }

    function _loadHub(string memory j, string memory p) internal pure returns (HubParams memory h) {
        h.name = vm.parseJsonString(j, string.concat(p, ".name"));
        h.band = uint8(vm.parseJsonUint(j, string.concat(p, ".band")));
        h.maxLiquidationDiscount = uint16(vm.parseJsonUint(j, string.concat(p, ".maxLiquidationDiscount")));
        h.interestFee = uint16(vm.parseJsonUint(j, string.concat(p, ".interestFee")));
        h.originationFeeBps = uint16(vm.parseJsonUint(j, string.concat(p, ".originationFeeBps")));
        h.irmBaseRate = vm.parseJsonUint(j, string.concat(p, ".irm.baseRate"));
        h.irmSlope1 = vm.parseJsonUint(j, string.concat(p, ".irm.slope1"));
        h.irmSlope2 = vm.parseJsonUint(j, string.concat(p, ".irm.slope2"));
        h.irmKink = uint32(vm.parseJsonUint(j, string.concat(p, ".irm.kink")));
        h.supplyCap = vm.parseJsonUint(j, string.concat(p, ".supplyCap"));
        h.borrowCap = vm.parseJsonUint(j, string.concat(p, ".borrowCap"));
        h.supplyCapCeiling = vm.parseJsonUint(j, string.concat(p, ".supplyCapCeiling"));
        h.borrowCapCeiling = vm.parseJsonUint(j, string.concat(p, ".borrowCapCeiling"));
        h.feeReceiver = vm.parseJsonAddress(j, string.concat(p, ".feeReceiver"));
    }

    // -- Assets ---------------------------------------------------------------------------------

    function loadAssets(string memory path) public view returns (AssetConfig[] memory a) {
        string memory j = vm.readFile(path);
        uint256 n = countJson(j, ".assets");
        a = new AssetConfig[](n);
        for (uint256 i; i < n; ++i) {
            string memory p = string.concat(".assets[", vm.toString(i), "]");
            a[i].symbol = vm.parseJsonString(j, string.concat(p, ".symbol"));
            a[i].token = vm.parseJsonAddress(j, string.concat(p, ".token"));
            a[i].mechanism = parseMechanism(vm.parseJsonString(j, string.concat(p, ".mechanism")));
            a[i].riskClass = parseRiskClass(vm.parseJsonString(j, string.concat(p, ".riskClass")));
            a[i].hubIndex = vm.parseJsonUint(j, string.concat(p, ".hubIndex"));
            a[i].seedAmount = vm.parseJsonUint(j, string.concat(p, ".seedAmount"));
            a[i].supplyCapCeiling = vm.parseJsonUint(j, string.concat(p, ".supplyCapCeiling"));
        }
    }

    function parseMechanism(string memory s) public pure returns (Mechanism) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("multiplier")) return Mechanism.Multiplier;
        if (h == keccak256("balance-changing")) return Mechanism.BalanceChanging;
        if (h == keccak256("distributing")) return Mechanism.Distributing;
        revert(string.concat("unknown mechanism: ", s));
    }

    function parseRiskClass(string memory s) public pure returns (uint8) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("BlueChip")) return 0;
        if (h == keccak256("M1")) return 1;
        if (h == keccak256("M2")) return 2;
        if (h == keccak256("M3")) return 3;
        revert(string.concat("unknown risk class: ", s));
    }

    function isWrapped(Mechanism m) public pure returns (bool) {
        return m != Mechanism.Multiplier;
    }

    // -- Deployment records ---------------------------------------------------------------------

    function deploymentJson(Deployment memory d) public returns (string memory) {
        string memory k = "deployment";
        vm.serializeAddress(k, "deployer", d.deployer);
        vm.serializeAddress(k, "timelock", d.timelock);
        vm.serializeAddress(k, "governor", d.governor);
        vm.serializeAddress(k, "router", d.router);
        vm.serializeAddress(k, "oracle", d.oracle);
        vm.serializeAddress(k, "adapter", d.adapter);
        vm.serializeAddress(k, "hubHook", d.hubHook);
        vm.serializeAddress(k, "feeRouter", d.feeRouter);
        vm.serializeAddress(k, "escrowHook", d.escrowHook);
        vm.serializeAddress(k, "wrapperFactory", d.wrapperFactory);
        vm.serializeAddress(k, "routerGovernor", d.routerGovernor);
        vm.serializeAddress(k, "steward", d.steward);
        vm.serializeAddress(k, "hubs", d.hubs);
        vm.serializeAddress(k, "irms", d.irms);
        return vm.serializeAddress(k, "earns", d.earns);
    }

    function loadDeployment(string memory path) public view returns (Deployment memory d) {
        string memory j = vm.readFile(path);
        d.deployer = vm.parseJsonAddress(j, ".deployer");
        d.timelock = vm.parseJsonAddress(j, ".timelock");
        d.governor = vm.parseJsonAddress(j, ".governor");
        d.router = vm.parseJsonAddress(j, ".router");
        d.oracle = vm.parseJsonAddress(j, ".oracle");
        d.adapter = vm.parseJsonAddress(j, ".adapter");
        d.hubHook = vm.parseJsonAddress(j, ".hubHook");
        d.feeRouter = vm.parseJsonAddress(j, ".feeRouter");
        d.escrowHook = vm.parseJsonAddress(j, ".escrowHook");
        d.wrapperFactory = vm.parseJsonAddress(j, ".wrapperFactory");
        d.routerGovernor = vm.parseJsonAddress(j, ".routerGovernor");
        d.steward = vm.parseJsonAddress(j, ".steward");
        d.hubs = vm.parseJsonAddressArray(j, ".hubs");
        d.irms = vm.parseJsonAddressArray(j, ".irms");
        d.earns = vm.parseJsonAddressArray(j, ".earns");
    }

    // -- Safe Transaction Builder ---------------------------------------------------------------

    /// @notice Safe Transaction Builder JSON for `txs`, executed by `safe` on `chainId`. Deterministic: no
    /// timestamp (`createdAt` is 0) and no checksum, so the same input always yields byte-identical output.
    function safeBatchJson(uint256 chainId, address safe, string memory name, SafeTx[] memory txs)
        public
        pure
        returns (string memory out)
    {
        out = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(chainId),
            '","createdAt":0,"meta":{"name":"',
            name,
            '","description":"Generated by script/BuildListingBatch.s.sol","txBuilderVersion":"1.16.5",',
            '"createdFromSafeAddress":"',
            vm.toString(safe),
            '","createdFromOwnerAddress":""},"transactions":['
        );
        for (uint256 i; i < txs.length; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(txs[i].to),
                '","value":"0","data":"',
                vm.toString(txs[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        out = string.concat(out, "]}");
    }
}
