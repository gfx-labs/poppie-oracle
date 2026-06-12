// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

/// @notice Configure all 25 BSC assets on the dev oracle + adapter.
///
/// Usage:
///   source .env && forge script script/ConfigureDev.s.sol \
///     --rpc-url $BSC_RPC_URL --broadcast
contract ConfigureDev is Script {
    // dev deployments
    address constant ORACLE  = 0xAECe46000C265e72C7Ba972F95EEe1cF80af549F;
    address constant ADAPTER = 0x1c3e111efc22032952914c23E907C20676280d33;

    // circuit breaker tiers (bps)
    uint256 constant CB_DEFAULT  = 5000;  // 50% — single stocks
    uint256 constant CB_ETF      = 3000;  // 30% — ETFs (SPY, QQQ)
    uint256 constant CB_LEVERAGE = 7500;  // 75% — leveraged/volatile (TQQQ, SQQQ, MSTR, RKLB)

    // cumulative deviation cap — same as CB for simplicity in dev
    uint256 constant CUM_DEFAULT  = 5000;
    uint256 constant CUM_ETF      = 3000;
    uint256 constant CUM_LEVERAGE = 7500;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");

        PoppieEulerOracle oracle = PoppieEulerOracle(ORACLE);
        PoppieEulerAdapter adapter = PoppieEulerAdapter(ADAPTER);

        // 25 BSC Ondo GM tokens
        address[25] memory tokens = [
            0xA9eE28C80f960B889dFbd1902055218cBa016F75, // NVDAon
            0x2494b603319d4D9F9715c9f4496d9E0364B59d93, // TSLAon
            0x091FC7778e6932d4009B087B191D1EE3bac5729A, // GOOGLon
            0x992879Cd8ce0c312d98648875B5A8D6D042cbF34, // CRCLon
            0x0cdE6936d305d5B34667fC46425E852efd73559a, // QQQon
            0x6Bfe75D1ad432050eA973C3A3DcD88F02e2444C3, // MSFTon
            0xA528CaaA2f96090e379d43F90834C75dF54D6E74, // INTCon
            0x8b6ACf6041A81567f012Ff6A4C6D96d5818d74bF, // MUon
            0x390a684EF9cADE28A7AD0DFa61AB1Eb3842618c4, // AAPLon
            0x6a708EAD771238919D85930b5a0f10454E1C331a, // SPYon
            0x4553cFe1C09f37f38b12dC509F676964e392F8Fc, // AMZNon
            0x4Fd67CB8CFEdc718BAc984b5936abE3330d0a2A4, // SNDKon
            0xD7dF5863A3e742F0c767768cDfcb63f09E0422f6, // METAon
            0x9f16E46c73b43BDB70861247d537bEE4eA18F639, // AMDon
            0xf8589b526FdD65F7F301c605a6e04F0F1b4B3620, // COINon
            0x7048F5227b032326cC8DBC53cF3FdDD947a2c757, // NFLXon
            0xe42CfB20e00912409B77A602B5BDcfF3c7aCC5F4, // TQQQon
            0x7313EA16493b2f55054Df0131A3A14B043ec8992, // MSTRon
            0xC37042A7a4fa510D8884a433762aB87257B91965, // TSMon
            0x03E4bd1Ea53f1da84513da0319D1f03dD1BBCf93, // ORCLon
            0x1501EC83FFEf405B4331CC4f73277a40fb0C627d, // MRVLon
            0xfBD4D681C92ead6Af0E49950c8B2e47EeAcbB2dB, // QCOMon
            0xb4D695569236273745B4CD54B539b1b9Cc1513af, // RKLBon
            0xd5964f3fcee8D649995AB88F04b8982539c282D2, // BABAon
            0x17515B68378d86C38F394c666e79907dA05dcBA9  // SQQQon
        ];

        // match thresholds to the production BSC deployment tiers
        uint256[25] memory cb = [
            CB_DEFAULT,  // NVDAon
            CB_DEFAULT,  // TSLAon
            CB_DEFAULT,  // GOOGLon
            CB_DEFAULT,  // CRCLon
            CB_ETF,      // QQQon
            CB_DEFAULT,  // MSFTon
            CB_DEFAULT,  // INTCon
            CB_DEFAULT,  // MUon
            CB_DEFAULT,  // AAPLon
            CB_ETF,      // SPYon
            CB_DEFAULT,  // AMZNon
            CB_DEFAULT,  // SNDKon
            CB_DEFAULT,  // METAon
            CB_DEFAULT,  // AMDon
            CB_DEFAULT,  // COINon
            CB_DEFAULT,  // NFLXon
            CB_LEVERAGE, // TQQQon
            CB_LEVERAGE, // MSTRon
            CB_DEFAULT,  // TSMon
            CB_DEFAULT,  // ORCLon
            CB_DEFAULT,  // MRVLon
            CB_DEFAULT,  // QCOMon
            CB_LEVERAGE, // RKLBon
            CB_DEFAULT,  // BABAon
            CB_LEVERAGE  // SQQQon
        ];

        uint256[25] memory cumCap = [
            CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,  CUM_ETF,
            CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,  CUM_ETF,
            CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,  CUM_DEFAULT,
            CUM_DEFAULT,  CUM_LEVERAGE, CUM_LEVERAGE, CUM_DEFAULT,  CUM_DEFAULT,
            CUM_DEFAULT,  CUM_DEFAULT,  CUM_LEVERAGE, CUM_DEFAULT,  CUM_LEVERAGE
        ];

        // convert fixed arrays to dynamic for the contract call
        address[] memory addrs = new address[](25);
        uint256[] memory cbs = new uint256[](25);
        uint256[] memory caps = new uint256[](25);
        for (uint256 i = 0; i < 25; i++) {
            addrs[i] = tokens[i];
            cbs[i] = cb[i];
            caps[i] = cumCap[i];
        }

        vm.startBroadcast(deployerKey);

        // configure all assets on the oracle
        console.log("Configuring 25 assets on oracle...");
        oracle.configureAssets(addrs, cbs, caps);

        // register all bases on the adapter with their on-chain decimals
        console.log("Registering 25 bases on adapter...");
        for (uint256 i = 0; i < 25; i++) {
            uint8 dec = IERC20(tokens[i]).decimals();
            adapter.registerBase(tokens[i], dec);
            console.log("  registered", tokens[i], "decimals", dec);
        }

        vm.stopBroadcast();
        console.log("Done.");
    }
}
