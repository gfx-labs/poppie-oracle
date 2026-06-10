// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedRateOracle} from "euler-price-oracle/adapter/fixed/FixedRateOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice In-scope coverage for the FixedRateOracle as Poppie deploys it.
///
/// FixedRateOracle is an UNMODIFIED contract from euler-price-oracle (vendored via the
/// lib/ dependency, not forked). Poppie uses one instance to price USDT 1:1 against the
/// USD unit of account (address(840), 18 decimals), so the keeper outage of an equity
/// feed can never freeze the borrowable asset. This test pins the exact production
/// configuration and the 1:1 quote behavior auditors should verify.
contract FixedRateOracleTest is Test {
    // Production unit of account: abstract USD per ERC-7535-style convention.
    address constant USD = address(840);
    uint8 constant USD_DECIMALS = 18;
    uint256 constant RATE_1E18 = 1e18; // 1 USDT == 1 USD, expressed in quote (USD) decimals

    MockERC20 usdt;
    FixedRateOracle oracle;

    function setUp() public {
        // BSC USDT is 18 decimals; mirror that so the scale math matches production.
        usdt = new MockERC20("Tether USD", "USDT", 18);
        // base = USDT, quote = USD(840), rate = 1e18 (quote decimals) -> 1:1.
        oracle = new FixedRateOracle(address(usdt), USD, RATE_1E18);
    }

    function test_config_matchesProduction() public view {
        assertEq(oracle.base(), address(usdt));
        assertEq(oracle.quote(), USD);
        assertEq(oracle.rate(), RATE_1E18);
    }

    function test_getQuote_oneToOne_usdtToUsd() public view {
        // 1 USDT (1e18) -> 1 USD (1e18)
        assertEq(oracle.getQuote(1e18, address(usdt), USD), 1e18);
        // 1234.5 USDT -> 1234.5 USD
        assertEq(oracle.getQuote(1234.5e18, address(usdt), USD), 1234.5e18);
    }

    function test_getQuote_inverse_usdToUsdt() public view {
        // The inverse direction (USD -> USDT) must also hold 1:1.
        assertEq(oracle.getQuote(1e18, USD, address(usdt)), 1e18);
    }

    function testFuzz_getQuote_linear(uint256 amount) public view {
        amount = bound(amount, 0, 1e30);
        assertEq(oracle.getQuote(amount, address(usdt), USD), amount);
    }

    function test_constructor_revertsOnZeroRate() public {
        vm.expectRevert();
        new FixedRateOracle(address(usdt), USD, 0);
    }
}
