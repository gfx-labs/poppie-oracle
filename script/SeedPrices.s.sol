// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";

interface IOracle {
    function adminSetPrice(address asset, uint128 price) external;
}

interface ISSO {
    function getSValue(address) external view returns (uint256);
}

/// @notice Seed initial prices on the post-audit oracle by reading current
///         Ondo share values from the on-chain SyntheticSharesOracle.
///
/// The post-audit contract requires every asset to have a non-zero lastPrice
/// (via adminSetPrice) before keeperPushPrices will accept updates. This
/// script reads each asset's current sValue from the Ondo SSO and seeds it
/// as the initial price. The keeper's next push will then update normally
/// since the seed is the real current price.
///
/// Usage:
///   source .env && ORACLE=0x8cCFe4A49614DE7F3204D436b254fC874De9AC76 \
///     forge script script/SeedPrices.s.sol --rpc-url $BSC_RPC_URL --broadcast
contract SeedPrices is Script {
    // BSC SyntheticSharesOracle
    ISSO constant SSO = ISSO(0xF4Fd8a1B412633e10527454137A29Db7Aa35F15e);

    function run() external {
        address oracle = vm.envAddress("ORACLE");
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");

        // All 25 BSC asset addresses
        address[25] memory assets = [
            address(0x390a684EF9cADE28A7AD0DFa61AB1Eb3842618c4),  // AAPLon
            address(0x9f16E46c73b43BDB70861247d537bEE4eA18F639),  // AMDon
            address(0x4553cFe1C09f37f38b12dC509F676964e392F8Fc),  // AMZNon
            address(0xd5964f3fcee8D649995AB88F04b8982539c282D2),  // BABAon
            address(0xf8589b526FdD65F7F301c605a6e04F0F1b4B3620),  // COINon
            address(0x992879Cd8ce0c312d98648875B5A8D6D042cbF34),  // CRCLon
            address(0x091FC7778e6932d4009B087B191D1EE3bac5729A),  // GOOGLon
            address(0xA528CaaA2f96090e379d43F90834C75dF54D6E74),  // INTCon
            address(0xD7dF5863A3e742F0c767768cDfcb63f09E0422f6),  // METAon
            address(0x1501EC83FFEf405B4331CC4f73277a40fb0C627d),  // MRVLon
            address(0x6Bfe75D1ad432050eA973C3A3DcD88F02e2444C3),  // MSFTon
            address(0x7313EA16493b2f55054Df0131A3A14B043ec8992),  // MSTRon
            address(0x8b6ACf6041A81567f012Ff6A4C6D96d5818d74bF),  // MUon
            address(0xA9eE28C80f960B889dFbd1902055218cBa016F75),  // NFLXon
            address(0x03E4bd1Ea53f1da84513da0319D1f03dD1BBCf93),  // NVDAon
            address(0x7048F5227b032326cC8DBC53cF3FdDD947a2c757),  // ORCLon
            address(0xfBD4D681C92ead6Af0E49950c8B2e47EeAcbB2dB),  // QCOMon
            address(0x0cdE6936d305d5B34667fC46425E852efd73559a),  // QQQon
            address(0xb4D695569236273745B4CD54B539b1b9Cc1513af),  // RKLBon
            address(0x4Fd67CB8CFEdc718BAc984b5936abE3330d0a2A4),  // SNDKon
            address(0x6a708EAD771238919D85930b5a0f10454E1C331a),  // SPYon
            address(0x17515B68378d86C38F394c666e79907dA05dcBA9),  // SQQQon
            address(0xe42CfB20e00912409B77A602B5BDcfF3c7aCC5F4),  // TQQQon
            address(0x2494b603319d4D9F9715c9f4496d9E0364B59d93),  // TSLAon
            address(0xC37042A7a4fa510D8884a433762aB87257B91965)   // TSMon
        ];

        console.log("Seeding prices on oracle:", oracle);
        console.log("Reading sValues from SSO:", address(SSO));

        vm.startBroadcast(deployerKey);

        IOracle o = IOracle(oracle);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 sValue = SSO.getSValue(assets[i]);
            require(sValue > 0, "sValue is zero");
            require(sValue <= type(uint128).max, "sValue exceeds uint128");
            uint128 price = uint128(sValue);
            o.adminSetPrice(assets[i], price);
            console.log("  seeded", assets[i], price);
        }

        console.log("Done: all 25 assets seeded with current sValues");
        vm.stopBroadcast();
    }
}
