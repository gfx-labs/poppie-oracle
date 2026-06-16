// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoppieEulerOracle} from "../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/PoppieEulerAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PoppieEulerAdapterSymbolicTest
/// @notice Halmos symbolic spec for the adapter's decimal-scaling math.
///         Run with:  halmos --match-contract PoppieEulerAdapterSymbolicTest
///
///         Proves getQuote equals the Math.mulDiv reference for fixed decimal
///         layouts over ALL symbolic inAmount/price. Concretizing the decimals
///         keeps 10**exp constant so the SMT problem stays tractable.
contract PoppieEulerAdapterSymbolicTest is Test {
    PoppieEulerOracle oracle;
    address admin = address(0xAD);
    address keeper = address(0xBE);
    address aAdmin = address(0xA1);
    address constant UNIT = address(840);

    function setUp() public {
        oracle = new PoppieEulerOracle(admin, keeper, 0, 0); // 0 => no staleness guard in proof
    }

    function _setup(uint8 baseDec, uint8 uoaDec, uint128 price18)
        internal
        returns (PoppieEulerAdapter adapter, MockERC20 token)
    {
        token = new MockERC20("T", "T", baseDec);
        adapter = new PoppieEulerAdapter(address(oracle), aAdmin, UNIT, uoaDec);

        address[] memory a = new address[](1);
        uint16[] memory t = new uint16[](1);
        a[0] = address(token);
        t[0] = 10000; // cumulative cap must be non-zero; admin seeds the price so no guard fires
        vm.prank(admin);
        oracle.configureAssets(a, t, t);

        uint8 dec = token.decimals();
        vm.prank(aAdmin);
        adapter.registerBase(address(token), dec);

        // admin seeds the symbolic price directly so the symbolic prover does not need
        // to model the keeper guards.
        vm.prank(admin);
        oracle.adminSetPrice(address(token), price18);
    }

    /// @notice (18,18): exp = 18. Proven equal to mulDiv reference for all inputs.
    function check_getQuote_eq_reference_18_18(uint256 inAmount, uint128 price) public {
        vm.assume(price > 0 && price <= 1e25);
        vm.assume(inAmount <= 1e30);
        (PoppieEulerAdapter adapter, MockERC20 token) = _setup(18, 18, price);
        uint256 expected = Math.mulDiv(inAmount, price, 1e18);
        assertEq(adapter.getQuote(inAmount, address(token), UNIT), expected);
    }

    /// @notice (6,18): exp = 6. Smaller base decimals path.
    function check_getQuote_eq_reference_6_18(uint256 inAmount, uint128 price) public {
        vm.assume(price > 0 && price <= 1e25);
        vm.assume(inAmount <= 1e24);
        (PoppieEulerAdapter adapter, MockERC20 token) = _setup(6, 18, price);
        uint256 expected = Math.mulDiv(inAmount, price, 1e6);
        assertEq(adapter.getQuote(inAmount, address(token), UNIT), expected);
    }

    /// @notice (18,6): exp = 30. The divide-heavy path that the legacy suite never
    ///         exercised (all prior unit tests used uoaDec == 18).
    function check_getQuote_eq_reference_18_6(uint256 inAmount, uint128 price) public {
        vm.assume(price > 0 && price <= 1e25);
        vm.assume(inAmount <= 1e30);
        (PoppieEulerAdapter adapter, MockERC20 token) = _setup(18, 6, price);
        uint256 expected = Math.mulDiv(inAmount, price, 10 ** 30);
        assertEq(adapter.getQuote(inAmount, address(token), UNIT), expected);
    }

    /// @notice Zero input always yields zero, any price/decimals.
    function check_getQuote_zeroIn(uint128 price) public {
        vm.assume(price > 0 && price <= 1e25);
        (PoppieEulerAdapter adapter, MockERC20 token) = _setup(18, 18, price);
        assertEq(adapter.getQuote(0, address(token), UNIT), 0);
    }
}
