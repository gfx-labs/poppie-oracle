// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract PoppieEulerAdapterTest is Test {
    PoppieEulerOracle oracle;
    PoppieEulerAdapter adapter;

    MockERC20 token18;
    MockERC20 token6;
    MockERC20 token8;

    address admin = address(0xAD);
    address keeper = address(0xBE);
    address aAdmin = address(0xA1); // adapter admin
    address user = address(0xCC);

    address constant UNIT = address(840);
    uint8 constant UNIT_DEC = 18;
    uint16 constant CB = 5000;

    event AdapterDeployed(
        address indexed master,
        address indexed unitOfAccount,
        uint8 unitOfAccountDecimals,
        address admin
    );

    function setUp() public {
        token18 = new MockERC20("AAPLon", "AAPLon", 18);
        token6 = new MockERC20("USDCon", "USDCon", 6);
        token8 = new MockERC20("WBTCon", "WBTCon", 8);

        oracle = new PoppieEulerOracle(admin, keeper, 3600, 86400);
        adapter = new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, UNIT_DEC);

        address[] memory a = new address[](3);
        uint16[] memory t = new uint16[](3);
        a[0] = address(token18); a[1] = address(token6); a[2] = address(token8);
        t[0] = CB; t[1] = CB; t[2] = CB;
        vm.prank(admin);
        oracle.configureAssets(a, t, t);

        // register bases on adapter
        vm.startPrank(aAdmin);
        adapter.registerBase(address(token18), token18.decimals());
        adapter.registerBase(address(token6), token6.decimals());
        adapter.registerBase(address(token8), token8.decimals());
        vm.stopPrank();

        // seed prices
        uint128[] memory p = new uint128[](3);
        p[0] = 175.23e18; p[1] = 1e18; p[2] = 67000e18;
        vm.prank(keeper);
        oracle.keeperPushPrices(a, p);
    }

    function _arr(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    // --- Constructor ---

    function test_constructor() public view {
        assertEq(address(adapter.master()), address(oracle));
        assertEq(adapter.admin(), aAdmin);
        assertEq(adapter.unitOfAccount(), UNIT);
        assertEq(adapter.unitOfAccountDecimals(), UNIT_DEC);
    }

    function test_constructor_emitsAdapterDeployed() public {
        vm.expectEmit(true, true, false, true);
        emit AdapterDeployed(address(oracle), UNIT, UNIT_DEC, aAdmin);
        new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, UNIT_DEC);
    }

    function test_constructor_revert_zeroMaster() public {
        vm.expectRevert(PoppieEulerAdapter.ZeroAddress.selector);
        new PoppieEulerAdapter(address(0), aAdmin, UNIT, UNIT_DEC);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(PoppieEulerAdapter.ZeroAddress.selector);
        new PoppieEulerAdapter(address(oracle), address(0), UNIT, UNIT_DEC);
    }

    function test_constructor_revert_zeroUnit() public {
        vm.expectRevert(PoppieEulerAdapter.ZeroAddress.selector);
        new PoppieEulerAdapter(address(oracle), aAdmin, address(0), UNIT_DEC);
    }

    function test_name() public view {
        assertEq(adapter.name(), "PoppieEulerAdapter");
    }

    // --- Base registration ---

    function test_registerBase_cachesDecimals() public {
        (bool reg, uint8 dec) = adapter.getBaseInfo(address(token6));
        assertTrue(reg);
        assertEq(dec, 6);
    }

    function test_registerBase_revert_notAdmin() public {
        MockERC20 t = new MockERC20("X", "X", 18);
        uint8 dec = t.decimals();
        vm.prank(user);
        vm.expectRevert(PoppieEulerAdapter.OnlyAdmin.selector);
        adapter.registerBase(address(t), dec);
    }

    function test_registerBase_revert_zero() public {
        vm.prank(aAdmin);
        vm.expectRevert(PoppieEulerAdapter.ZeroAddress.selector);
        adapter.registerBase(address(0), 18);
    }

    function test_registerBase_revert_alreadyRegistered() public {
        uint8 dec = token18.decimals();
        vm.prank(aAdmin);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.BaseAlreadyRegistered.selector, address(token18)));
        adapter.registerBase(address(token18), dec);
    }

    function test_registerBase_revert_decimalsTooLarge() public {
        MockERC20 t = new MockERC20("X", "X", 18);
        vm.prank(aAdmin);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.DecimalsTooLarge.selector, 19));
        adapter.registerBase(address(t), 19);
    }

    function test_registerBase_explicitDecimals() public {
        MockERC20 t = new MockERC20("X", "X", 18);
        vm.prank(aAdmin);
        adapter.registerBase(address(t), 9);
        (bool reg, uint8 dec) = adapter.getBaseInfo(address(t));
        assertTrue(reg);
        assertEq(dec, 9);
    }

    function test_unregisterBase() public {
        vm.prank(aAdmin);
        adapter.unregisterBase(address(token18));
        (bool reg,) = adapter.getBaseInfo(address(token18));
        assertFalse(reg);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.BaseNotRegistered.selector, address(token18)));
        adapter.getQuote(1e18, address(token18), UNIT);
    }

    function test_transferAdmin_twoStep() public {
        vm.prank(aAdmin);
        adapter.transferAdmin(address(0xEE));
        assertEq(adapter.admin(), aAdmin); // not changed yet
        assertEq(adapter.pendingAdmin(), address(0xEE));

        vm.prank(address(0xEE));
        adapter.acceptAdmin();
        assertEq(adapter.admin(), address(0xEE));
        assertEq(adapter.pendingAdmin(), address(0));
    }

    // --- getQuote correctness ---

    function test_getQuote_18dec() public view {
        assertEq(adapter.getQuote(1e18, address(token18), UNIT), 175.23e18);
    }

    function test_getQuote_6dec() public view {
        assertEq(adapter.getQuote(1e6, address(token6), UNIT), 1e18);
    }

    function test_getQuote_8dec() public view {
        assertEq(adapter.getQuote(1e8, address(token8), UNIT), 67000e18);
    }

    function test_getQuote_zero() public view {
        assertEq(adapter.getQuote(0, address(token18), UNIT), 0);
    }

    function test_getQuotes_identical() public view {
        (uint256 bid, uint256 ask) = adapter.getQuotes(1e18, address(token18), UNIT);
        assertEq(bid, ask);
        assertEq(bid, 175.23e18);
    }

    function test_getQuote_revert_unsupportedQuote() public {
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.UnsupportedQuote.selector, address(0x999)));
        adapter.getQuote(1e18, address(token18), address(0x999));
    }

    function test_getQuote_revert_baseNotRegistered() public {
        MockERC20 t = new MockERC20("X", "X", 18);
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.BaseNotRegistered.selector, address(t)));
        adapter.getQuote(1e18, address(t), UNIT);
    }

    function test_getQuote_revert_staleMasterPrice() public {
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(IPoppieEulerOracle.StalePrice.selector);
        adapter.getQuote(1e18, address(token18), UNIT);
    }

    function test_getQuote_usesCachedDecimals_notLive() public {
        // Change the live token decimals AFTER registration; quote must use cached value.
        token18.setDecimals(6);
        // cached decimals is still 18, so 1e18 in -> 175.23e18 out (not 1e30-scaled)
        assertEq(adapter.getQuote(1e18, address(token18), UNIT), 175.23e18);
    }

    // --- Fuzz: conversion matches reference, realistic decimal range ---

    function testFuzz_getQuote_matchesReference(
        uint8 baseDec,
        uint256 inAmount,
        uint256 priceRaw
    ) public {
        baseDec = uint8(bound(baseDec, 0, 18));
        uint128 price18 = uint128(bound(priceRaw, 1e14, 1e25));
        inAmount = bound(inAmount, 0, 1e12 * (10 ** uint256(baseDec)));

        MockERC20 t = new MockERC20("F", "F", baseDec);
        uint16[] memory th = new uint16[](1);
        th[0] = 0; // disable CB for arbitrary price
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th, th);
        uint8 dec = t.decimals();
        vm.prank(aAdmin);
        adapter.registerBase(address(t), dec);
        uint128[] memory p = new uint128[](1);
        p[0] = price18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);

        // reference: baseDec in [0,18], UNIT_DEC = 18 => exp = baseDec >= 0 always
        uint256 expected = Math.mulDiv(inAmount, uint256(price18), 10 ** uint256(baseDec));
        assertEq(adapter.getQuote(inAmount, address(t), UNIT), expected);
    }

    // --- H-1 fix: unitOfAccountDecimals is now bounded at the constructor ---

    function test_H1_constructor_revert_unitDecimalsTooLarge() public {
        // Previously a UoA-decimals > baseDecimals+18 adapter bricked every quote with
        // an underflow. The fix bounds unitOfAccountDecimals at deploy time.
        vm.expectRevert(abi.encodeWithSelector(PoppieEulerAdapter.DecimalsTooLarge.selector, 19));
        new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 19);
    }

    function test_H1_constructor_acceptsMaxUnitDecimals() public {
        // 18 is the maximum allowed and must succeed.
        PoppieEulerAdapter a18 = new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, 18);
        assertEq(a18.unitOfAccountDecimals(), 18);
    }

    // --- M-1 fix: large positions no longer overflow (Math.mulDiv) ---

    function test_M1_largeAmount_noOverflow() public {
        // Previously `inAmount * price` overflowed uint256 and reverted. With mulDiv the
        // multiply-then-divide uses a 512-bit intermediate, so this computes correctly.
        // token18 is 18 decimals, price 175.23e18, UoA 18 decimals => exp = 18.
        // expected = mulDiv(huge, 175.23e18, 1e18)
        uint256 huge = type(uint256).max / 1e20;
        uint256 expected = Math.mulDiv(huge, 175.23e18, 1e18);
        uint256 got = adapter.getQuote(huge, address(token18), UNIT);
        assertEq(got, expected);
    }

    function test_M1_largeAmount_stillBoundedByUint256() public {
        // mulDiv removes the *intermediate* overflow, but a result that genuinely
        // exceeds uint256 must still revert. Pick inputs whose true quotient > 2^256.
        // price 175.23e18, exp=18 => result ~ inAmount * 175.23, so inAmount near max overflows the result.
        vm.expectRevert(); // Math.mulDiv reverts when the final result exceeds uint256
        adapter.getQuote(type(uint256).max, address(token18), UNIT);
    }

    function testFuzz_getQuote_zeroIn(uint8 baseDec, uint256 priceRaw) public {
        baseDec = uint8(bound(baseDec, 0, 18));
        uint128 price18 = uint128(bound(priceRaw, 1e14, 1e25));
        MockERC20 t = new MockERC20("F", "F", baseDec);
        uint16[] memory th = new uint16[](1);
        th[0] = 0;
        vm.prank(admin);
        oracle.configureAssets(_arr(address(t)), th, th);
        uint8 dec = t.decimals();
        vm.prank(aAdmin);
        adapter.registerBase(address(t), dec);
        uint128[] memory p = new uint128[](1);
        p[0] = price18;
        vm.prank(keeper);
        oracle.keeperPushPrices(_arr(address(t)), p);

        assertEq(adapter.getQuote(0, address(t), UNIT), 0);
    }
}
