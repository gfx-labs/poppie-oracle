// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";

/// @notice Dev deployment script for BSC mainnet.
///
/// Usage:
///   DEPLOYER_KEY=0x... ADMIN=0x... KEEPER=0x... forge script script/DeployDev.s.sol \
///     --rpc-url https://bsc-dataseed.binance.org --broadcast --verify
///
/// ADMIN  = the Safe or EOA that will admin both contracts (can be the deployer for dev).
/// KEEPER = the KMS-derived address that will push prices.
///
/// NOTE (audit L-03, accepted out-of-scope): the auditor flagged loading
/// `DEPLOYER_KEY` from an environment variable as an anti-pattern because
/// env vars leak through process inspection, CI logs, shell history,
/// container metadata, and log aggregators. We acknowledge this — for any
/// production deployment with meaningful admin authority the deployer
/// should be a Foundry keystore (`cast wallet import`, then `--account`),
/// a hardware signer (`--ledger`, `--trezor`), or a KMS-backed signer
/// rather than a raw env-var key. These dev scripts retain the env-var
/// path for repeatability; a separate production deploy script should
/// not.
///
/// After deployment, the admin must:
///   1. oracle.configureAssets(addresses, cbThresholds, cumCaps)
///   2. adapter.registerBase(token, decimals) for each asset
contract DeployDev is Script {
    // unit of account: abstract USD per ERC-7726 convention
    address constant UNIT_OF_ACCOUNT = address(840);
    uint8 constant UNIT_DECIMALS = 18;

    // oracle params
    uint256 constant MAX_PRICE_AGE = 3600;   // 1 hour
    uint256 constant ANCHOR_WINDOW = 86400;  // 24 hours

    function run() external {
        address admin = vm.envAddress("ADMIN");
        address keeper = vm.envAddress("KEEPER");
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");

        console.log("deployer:", vm.addr(deployerKey));
        console.log("admin:", admin);
        console.log("keeper:", keeper);

        vm.startBroadcast(deployerKey);

        // deploy oracle
        PoppieEulerOracle oracle = new PoppieEulerOracle(
            admin,
            keeper,
            MAX_PRICE_AGE,
            ANCHOR_WINDOW
        );
        console.log("PoppieEulerOracle:", address(oracle));

        // deploy adapter pointing at the oracle
        PoppieEulerAdapter adapter = new PoppieEulerAdapter(
            address(oracle),
            admin,
            UNIT_OF_ACCOUNT,
            UNIT_DECIMALS
        );
        console.log("PoppieEulerAdapter:", address(adapter));

        vm.stopBroadcast();
    }
}
