// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";

import {PoppieTestBase} from "../harness/PoppieTestBase.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";

/// @notice Proves the local harness: an EVK vault deployed through the factory, a price routed through
/// EulerRouter (escrow shares -> token -> USD), and an EVC-batched borrow that depends on that price. No fork.
contract HarnessSmokeTest is PoppieTestBase {
    MockPriceAdapter internal adapter;
    IEVault internal hub;
    IEVault internal escrow;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    uint256 internal constant STOCK_PRICE = 200e18; // USD per whole stock token, 18 decimals
    uint256 internal constant USDC_PRICE = 1e18;

    function setUp() public override {
        super.setUp();

        adapter = new MockPriceAdapter();
        adapter.setPrice(address(stock), STOCK_PRICE);
        adapter.setPrice(address(usdc), USDC_PRICE);

        hub = _createHub();
        escrow = _createEscrow(address(stock));

        // Router: (token, USD) -> adapter, escrow shares resolve to the token. Router governor is this test.
        router.govSetConfig(address(stock), USD, address(adapter));
        router.govSetConfig(address(usdc), USD, address(adapter));
        router.govSetResolvedVault(address(escrow), true);

        hub.setMaxLiquidationDiscount(0.1e4);
        hub.setLTV(address(escrow), 0.5e4, 0.6e4, 0);
        hub.setCaps(0, 0);
    }

    function test_factoryDeploysVaults() public view {
        assertTrue(factory.isProxy(address(hub)));
        assertTrue(factory.isProxy(address(escrow)));
        assertEq(factory.getProxyConfig(address(hub)).upgradeable, true);
        assertEq(factory.getProxyConfig(address(escrow)).upgradeable, false);

        assertEq(hub.asset(), address(usdc));
        assertEq(hub.oracle(), address(router));
        assertEq(hub.unitOfAccount(), USD);
        assertEq(hub.EVC(), address(evc));
        assertEq(escrow.asset(), address(stock));
        assertEq(escrow.oracle(), address(0));
        assertEq(escrow.governorAdmin(), address(this));
    }

    function test_routerRoutesPrice() public {
        // Token price straight through the configured adapter.
        assertEq(router.getQuote(1e18, address(stock), USD), STOCK_PRICE);
        (uint256 bid, uint256 ask) = router.getQuotes(2e18, address(stock), USD);
        assertEq(bid, 2 * STOCK_PRICE);
        assertEq(ask, 2 * STOCK_PRICE);

        // Escrow shares resolve to the token through convertToAssets, then price through the adapter.
        stock.mint(borrower, 10e18);
        vm.startPrank(borrower);
        stock.approve(address(escrow), 10e18);
        uint256 shares = escrow.deposit(10e18, borrower);
        vm.stopPrank();
        assertEq(router.getQuote(shares, address(escrow), USD), 10 * STOCK_PRICE);

        // An unconfigured pair reverts.
        vm.expectRevert();
        router.getQuote(1e18, address(escrow), address(123));
    }

    function test_borrowAgainstRoutedPrice() public {
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(hub), 1_000_000e6);
        hub.deposit(1_000_000e6, lender);
        vm.stopPrank();

        // 10 stock = 2,000 USD; LTV 50% at the bid -> up to 1,000 USDC of borrowing power.
        stock.mint(borrower, 10e18);
        vm.startPrank(borrower);
        stock.approve(address(escrow), 10e18);
        escrow.deposit(10e18, borrower);
        evc.enableCollateral(borrower, address(escrow));
        evc.enableController(borrower, address(hub));

        hub.borrow(900e6, borrower);
        assertEq(usdc.balanceOf(borrower), 900e6);
        assertEq(hub.debtOf(borrower), 900e6);

        // Health is priced through the router: 2,000 USD of collateral x 50% borrow LTV vs 900 USD of debt.
        (uint256 collateralValue, uint256 liabilityValue) = hub.accountLiquidity(borrower, false);
        assertEq(collateralValue, 1000e18);
        assertEq(liabilityValue, 900e18);

        // 1,100 USDC would exceed the 1,000 USDC of borrowing power.
        vm.expectRevert();
        hub.borrow(200e6, borrower);
        vm.stopPrank();
    }
}
