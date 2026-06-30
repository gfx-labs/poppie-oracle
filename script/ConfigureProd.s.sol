// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

/// @notice Configure the 21 supported assets on the prod oracle + adapter.
///         Excludes MRVL, QCOM, SQQQ, TQQQ (no Chainlink Data Streams coverage).
contract ConfigureProd is Script {
    address constant ORACLE  = 0xAE83F1A1Ea8a4e7CbcaC3551B88E22Baea25f26D;
    address constant ADAPTER = 0x92dad5eEE3245c2aD9766225Ff15beDf650646ea;

    uint256 constant CB_DEFAULT  = 5000;  // 50%
    uint256 constant CB_ETF      = 3000;  // 30%
    uint256 constant CB_LEVERAGE = 7500;  // 75%
    uint256 constant CUM_DEFAULT = 5000;
    uint256 constant CUM_ETF     = 3000;
    uint256 constant CUM_LEVERAGE = 7500;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");

        // 21 assets (no MRVL, QCOM, SQQQ, TQQQ)
        address[21] memory tokens = [
            address(0x390a684EF9cADE28A7AD0DFa61AB1Eb3842618c4),  // AAPLon
            address(0x9f16E46c73b43BDB70861247d537bEE4eA18F639),  // AMDon
            address(0x4553cFe1C09f37f38b12dC509F676964e392F8Fc),  // AMZNon
            address(0xd5964f3fcee8D649995AB88F04b8982539c282D2),  // BABAon
            address(0xf8589b526FdD65F7F301c605a6e04F0F1b4B3620),  // COINon
            address(0x992879Cd8ce0c312d98648875B5A8D6D042cbF34),  // CRCLon
            address(0x091FC7778e6932d4009B087B191D1EE3bac5729A),  // GOOGLon
            address(0xA528CaaA2f96090e379d43F90834C75dF54D6E74),  // INTCon
            address(0xD7dF5863A3e742F0c767768cDfcb63f09E0422f6),  // METAon
            address(0x6Bfe75D1ad432050eA973C3A3DcD88F02e2444C3),  // MSFTon
            address(0x7313EA16493b2f55054Df0131A3A14B043ec8992),  // MSTRon
            address(0x8b6ACf6041A81567f012Ff6A4C6D96d5818d74bF),  // MUon
            address(0x7048F5227b032326cC8DBC53cF3FdDD947a2c757),  // NFLXon
            address(0xA9eE28C80f960B889dFbd1902055218cBa016F75),  // NVDAon
            address(0x03E4bd1Ea53f1da84513da0319D1f03dD1BBCf93),  // ORCLon
            address(0x0cdE6936d305d5B34667fC46425E852efd73559a),  // QQQon
            address(0xb4D695569236273745B4CD54B539b1b9Cc1513af),  // RKLBon
            address(0x4Fd67CB8CFEdc718BAc984b5936abE3330d0a2A4),  // SNDKon
            address(0x6a708EAD771238919D85930b5a0f10454E1C331a),  // SPYon
            address(0x2494b603319d4D9F9715c9f4496d9E0364B59d93),  // TSLAon
            address(0xC37042A7a4fa510D8884a433762aB87257B91965)   // TSMon
        ];

        uint256[21] memory cb = [
            CB_DEFAULT,  // AAPLon
            CB_DEFAULT,  // AMDon
            CB_DEFAULT,  // AMZNon
            CB_DEFAULT,  // BABAon
            CB_DEFAULT,  // COINon
            CB_DEFAULT,  // CRCLon
            CB_DEFAULT,  // GOOGLon
            CB_DEFAULT,  // INTCon
            CB_DEFAULT,  // METAon
            CB_DEFAULT,  // MSFTon
            CB_LEVERAGE, // MSTRon
            CB_DEFAULT,  // MUon
            CB_DEFAULT,  // NFLXon
            CB_DEFAULT,  // NVDAon
            CB_DEFAULT,  // ORCLon
            CB_ETF,      // QQQon
            CB_LEVERAGE, // RKLBon
            CB_DEFAULT,  // SNDKon
            CB_ETF,      // SPYon
            CB_DEFAULT,  // TSLAon
            CB_DEFAULT   // TSMon
        ];

        uint256[21] memory cumCap = [
            CUM_DEFAULT,  // AAPLon
            CUM_DEFAULT,  // AMDon
            CUM_DEFAULT,  // AMZNon
            CUM_DEFAULT,  // BABAon
            CUM_DEFAULT,  // COINon
            CUM_DEFAULT,  // CRCLon
            CUM_DEFAULT,  // GOOGLon
            CUM_DEFAULT,  // INTCon
            CUM_DEFAULT,  // METAon
            CUM_DEFAULT,  // MSFTon
            CUM_LEVERAGE, // MSTRon
            CUM_DEFAULT,  // MUon
            CUM_DEFAULT,  // NFLXon
            CUM_DEFAULT,  // NVDAon
            CUM_DEFAULT,  // ORCLon
            CUM_ETF,      // QQQon
            CUM_LEVERAGE, // RKLBon
            CUM_DEFAULT,  // SNDKon
            CUM_ETF,      // SPYon
            CUM_DEFAULT,  // TSLAon
            CUM_DEFAULT   // TSMon
        ];

        address[] memory addrs = new address[](21);
        uint16[] memory cbs = new uint16[](21);
        uint16[] memory caps = new uint16[](21);
        for (uint256 i = 0; i < 21; i++) {
            addrs[i] = tokens[i];
            cbs[i] = uint16(cb[i]);
            caps[i] = uint16(cumCap[i]);
        }

        vm.startBroadcast(deployerKey);

        console.log("Configuring 21 assets on oracle...");
        PoppieEulerOracle(ORACLE).configureAssets(addrs, cbs, caps);

        console.log("Registering 21 bases on adapter...");
        PoppieEulerAdapter adapter = PoppieEulerAdapter(ADAPTER);
        for (uint256 i = 0; i < 21; i++) {
            uint8 dec = IERC20(tokens[i]).decimals();
            adapter.registerBase(tokens[i], dec);
            console.log("  registered", tokens[i], "decimals", dec);
        }

        vm.stopBroadcast();
        console.log("Done.");
    }
}
