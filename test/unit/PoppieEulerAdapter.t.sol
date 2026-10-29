// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {PoppieEulerAdapter} from "../../src/oracle/PoppieEulerAdapter.sol";

import {OracleFixture} from "../harness/OracleFixture.sol";

/// @notice Unit tests for `PoppieEulerAdapter` (CONTRACT_SPEC.md section 3.2): the three-state table, rounding,
/// decimals scaling and input validation. A is 18 decimals (h 10%), B is 6 (h 15%), C is 8 (h 30%).
contract PoppieEulerAdapterTest is OracleFixture {
    address internal usd = address(840);
    address internal a;
    address internal b;
    address internal c;

    function setUp() public override {
        super.setUp();
        a = address(tokenA);
        b = address(tokenB);
        c = address(tokenC);
    }

    function _quotes(address base, uint256 amount) internal view returns (uint256 bid, uint256 ask) {
        return adapter.getQuotes(amount, base, usd);
    }

    // -- Wiring ----------------------------------------------------------------------------------

    function test_immutables() public view {
        assertEq(address(adapter.oracle()), address(oracle));
        assertEq(adapter.USD(), address(840));
        assertEq(IPriceOracle(address(adapter)).name(), "PoppieEulerAdapter");
    }

    function test_unsupportedPairs() public {
        address other = makeAddr("other");
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerAdapter.UnsupportedPair.selector, a, other));
        adapter.getQuote(1e18, a, other);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerAdapter.UnsupportedPair.selector, a, other));
        adapter.getQuotes(1e18, a, other);
        // Inverse direction (USD as base) is not a listed token.
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerAdapter.UnsupportedPair.selector, usd, a));
        adapter.getQuote(1e18, usd, a);
        // Unlisted base.
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerAdapter.UnsupportedPair.selector, other, usd));
        adapter.getQuote(1e18, other, usd);
        vm.expectRevert(abi.encodeWithSelector(IPoppieEulerAdapter.UnsupportedPair.selector, other, usd));
        adapter.getQuotes(1e18, other, usd);
    }

    // -- Live ------------------------------------------------------------------------------------

    function test_live_midBidAskEqualL() public {
        _goLive(a, _price(100));
        assertEq(adapter.getQuote(2e18, a, usd), 200e18);
        (uint256 bid, uint256 ask) = _quotes(a, 2e18);
        assertEq(bid, 200e18);
        assertEq(ask, 200e18);
    }

    function test_live_scalesByDecimals() public {
        _goLive(b, _price(50)); // 6 decimals
        _goLive(c, _price(7)); // 8 decimals
        assertEq(adapter.getQuote(3e6, b, usd), 150e18);
        assertEq(adapter.getQuote(25e6, c, usd), 175e16); // 0.25 token at $7
        (uint256 bid, uint256 ask) = _quotes(c, 1e8);
        assertEq(bid, 7e18);
        assertEq(ask, 7e18);
    }

    function test_live_roundingDownForMidAndBidUpForAsk() public {
        // 1 base unit of a 6-decimals token at $1.5 per token: 1.5e18 / 1e6 = 1.5e12 exactly; use a price that
        // does not divide: 1e18 + 1 per token, 1 base unit (6 dec): (1e18 + 1) / 1e6 = 1e12 + 0.000001.
        _goLive(b, uint128(1e18 + 1));
        assertEq(adapter.getQuote(1, b, usd), 1e12);
        (uint256 bid, uint256 ask) = _quotes(b, 1);
        assertEq(bid, 1e12);
        assertEq(ask, 1e12 + 1);
        assertLe(bid, adapter.getQuote(1, b, usd));
        assertLe(adapter.getQuote(1, b, usd), ask);
    }

    function test_live_zeroAmount() public {
        _goLive(a, _price(100));
        assertEq(adapter.getQuote(0, a, usd), 0);
        (uint256 bid, uint256 ask) = _quotes(a, 0);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    // -- Closed ----------------------------------------------------------------------------------

    function test_closed_paused() public {
        _goLive(a, _price(100));
        _pause(a);
        vm.expectRevert(IPoppieEulerAdapter.PriceUnavailable.selector);
        adapter.getQuote(1e18, a, usd);
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 90e18); // L * (1 - 10%)
        assertEq(ask, 100e18);
    }

    function test_closed_stale() public {
        _goLive(b, _price(100));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(IPoppieEulerAdapter.PriceUnavailable.selector);
        adapter.getQuote(1e6, b, usd);
        (uint256 bid, uint256 ask) = _quotes(b, 1e6);
        assertEq(bid, 85e18); // M1: 15%
        assertEq(ask, 100e18);
    }

    function test_closed_neverPriced() public {
        vm.expectRevert(IPoppieEulerAdapter.PriceUnavailable.selector);
        adapter.getQuote(1e18, a, usd);
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_closed_bidRoundsDownThroughTheHaircut() public {
        _goLive(b, 1_000_000_000_000_000_001); // L = 1e18 + 1
        _pause(b);
        // 1e6 base units: L * 0.85 = 0.85e18 + 0.85 -> floor.
        (uint256 bid, uint256 ask) = _quotes(b, 1e6);
        assertEq(bid, 85e16 + 0);
        assertEq(ask, 1e18 + 1);
    }

    // -- Unconfirmed -----------------------------------------------------------------------------

    function test_unconfirmed_upMove() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        vm.expectRevert(IPoppieEulerAdapter.PriceUnconfirmed.selector);
        adapter.getQuote(1e18, a, usd);
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 90e18); // min(150, 90)
        assertEq(ask, 150e18); // max(150, 100)
    }

    function test_unconfirmed_downMove() public {
        _goLive(a, _price(100));
        _push(a, _price(50));
        vm.expectRevert(IPoppieEulerAdapter.PriceUnconfirmed.selector);
        adapter.getQuote(1e18, a, usd);
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 50e18); // min(50, 90)
        assertEq(ask, 100e18); // max(50, 100)
    }

    function test_unconfirmed_pendingBetweenHaircutAndL_afterHaircutRaise() public {
        _goLive(a, _price(100));
        _push(a, _price(85)); // beyond 10%
        vm.prank(ops);
        oracle.setClassHaircut(IPoppieEulerOracle.PriceClass.BlueChip, 2000); // now h = 20%: L(1-h) = 80
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 80e18); // min(85, 80): the bid never rises above L(1-h)
        assertEq(ask, 100e18);
    }

    function test_unconfirmed_firstPrice_bidIsZero() public {
        _push(a, _price(100));
        vm.expectRevert(IPoppieEulerAdapter.PriceUnconfirmed.selector);
        adapter.getQuote(1e18, a, usd);
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 0);
        assertEq(ask, 100e18);
    }

    function test_unconfirmed_pausedIsClosed() public {
        _goLive(a, _price(100));
        _push(a, _price(150));
        _pause(a);
        vm.expectRevert(IPoppieEulerAdapter.PriceUnavailable.selector);
        adapter.getQuote(1e18, a, usd);
        (uint256 bid, uint256 ask) = _quotes(a, 1e18);
        assertEq(bid, 90e18);
        assertEq(ask, 100e18); // the pending price is ignored while Closed
    }

    // -- Transitions seen through the adapter ----------------------------------------------------

    function test_lifecycle() public {
        // never priced -> unconfirmed first price -> live -> closed (age) -> live (in-bound) -> unconfirmed ->
        // live (confirm) -> unconfirmed -> live (n pushes)
        _push(a, _price(100));
        _assertMidReverts(a, IPoppieEulerAdapter.PriceUnconfirmed.selector);
        _confirm(a, _price(100));
        assertEq(adapter.getQuote(1e18, a, usd), 100e18);

        vm.warp(block.timestamp + 2 hours);
        _assertMidReverts(a, IPoppieEulerAdapter.PriceUnavailable.selector);
        _push(a, _price(104));
        assertEq(adapter.getQuote(1e18, a, usd), 104e18);

        _push(a, _price(300));
        _assertMidReverts(a, IPoppieEulerAdapter.PriceUnconfirmed.selector);
        _confirm(a, _price(300));
        assertEq(adapter.getQuote(1e18, a, usd), 300e18);

        _push(a, _price(10));
        _assertMidReverts(a, IPoppieEulerAdapter.PriceUnconfirmed.selector);
        vm.warp(block.timestamp + 10 minutes);
        _push(a, _price(10));
        vm.warp(block.timestamp + 10 minutes);
        _push(a, _price(10));
        assertEq(adapter.getQuote(1e18, a, usd), 10e18);
    }

    function _assertMidReverts(address base, bytes4 sel) internal {
        vm.expectRevert(sel);
        adapter.getQuote(1e18, base, usd);
    }

    // -- Extremes --------------------------------------------------------------------------------

    function test_largeAmountsDoNotOverflowIntermediate() public {
        _goLive(a, type(uint128).max);
        // inAmount * price * 1e4 is above 2^256 here: mulDiv must handle the 512-bit intermediate.
        uint256 amount = type(uint128).max;
        uint256 expected = amount * (uint256(type(uint128).max) / 1e18);
        (uint256 bid, uint256 ask) = _quotes(a, amount);
        assertApproxEqRel(bid, expected, 1e9);
        assertGe(ask, bid);
    }

    function test_resultOverflowReverts() public {
        _goLive(a, type(uint128).max);
        vm.expectRevert();
        adapter.getQuote(type(uint256).max, a, usd);
    }
}
