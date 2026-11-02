// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Governable} from "euler-price-oracle/lib/Governable.sol";
import {Errors as OracleErrors} from "euler-price-oracle/lib/Errors.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {OP_DEPOSIT, OP_WITHDRAW} from "evk/EVault/shared/Constants.sol";

import {PoppieRouterGovernor} from "../../src/governance/PoppieRouterGovernor.sol";
import {IPoppieRouterGovernor} from "../../src/interfaces/IPoppieRouterGovernor.sol";
import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {PoppieWrapperFactory} from "../../src/wrapper/PoppieWrapperFactory.sol";
import {ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS} from "../../src/access/Roles.sol";

import {MockEscrowHook} from "../mocks/MockEscrowHook.sol";
import {RouterGovernorFixture} from "../harness/RouterGovernorFixture.sol";

contract PoppieRouterGovernorTest is RouterGovernorFixture {
    IPoppieRouterGovernor internal rg;

    function setUp() public override {
        super.setUp();
        // Every call goes through the interface type, which also pins the ABI.
        rg = IPoppieRouterGovernor(address(routerGovernor));
    }

    // -- Constructor and views ------------------------------------------------------------------

    function test_constructor() public view {
        assertEq(rg.router(), address(router));
        assertEq(rg.adapter(), address(adapter));
        assertEq(rg.wrapperFactory(), address(wrapperFactory));
        assertEq(rg.vaultFactory(), address(factory));
        assertEq(rg.poppieGovernor(), address(governor));
        assertEq(rg.escrowHook(), address(escrowHook));
        assertTrue(routerGovernor.hasRole(routerGovernor.DEFAULT_ADMIN_ROLE(), timelock));
        assertTrue(routerGovernor.hasRole(MS_OPS, ops));
        assertEq(router.governor(), address(routerGovernor));
        assertFalse(rg.isApprovedToken(address(stock)));
    }

    function test_constructorRejectsZero() public {
        address[7] memory args = [
            timelock,
            address(router),
            address(adapter),
            address(wrapperFactory),
            address(factory),
            address(governor),
            address(escrowHook)
        ];
        for (uint256 i; i < args.length; ++i) {
            address[7] memory a = args;
            a[i] = address(0);
            vm.expectRevert(IPoppieRouterGovernor.ZeroAddress.selector);
            new PoppieRouterGovernor(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
        }
    }

    // -- setApprovedToken -----------------------------------------------------------------------

    function test_setApprovedToken() public {
        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.ApprovedTokenSet(address(stock), true);
        vm.prank(timelock);
        rg.setApprovedToken(address(stock), true);
        assertTrue(rg.isApprovedToken(address(stock)));

        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.ApprovedTokenSet(address(stock), false);
        vm.prank(timelock);
        rg.setApprovedToken(address(stock), false);
        assertFalse(rg.isApprovedToken(address(stock)));
    }

    function test_setApprovedTokenRejectsZero() public {
        vm.prank(timelock);
        vm.expectRevert(IPoppieRouterGovernor.ZeroAddress.selector);
        rg.setApprovedToken(address(0), true);
    }

    function test_setApprovedTokenOnlyAdmin() public {
        _expectUnauthorized(ops, routerGovernor.DEFAULT_ADMIN_ROLE());
        rg.setApprovedToken(address(stock), true);
    }

    // -- addRoute -------------------------------------------------------------------------------

    function test_addRoute() public {
        _approve(address(stock));
        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.RouteAdded(address(stock), address(adapter));
        _addRoute(address(stock));
        assertEq(router.getConfiguredOracle(address(stock), USD), address(adapter));
    }

    function test_addRouteRejectsNotApproved() public {
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.TokenNotApproved.selector, address(stock)));
        rg.addRoute(address(stock));
    }

    function test_addRouteRejectsUnapprovedAgain() public {
        _approve(address(stock));
        vm.prank(timelock);
        rg.setApprovedToken(address(stock), false);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.TokenNotApproved.selector, address(stock)));
        rg.addRoute(address(stock));
    }

    function test_addRouteIsAddOnly() public {
        _approve(address(stock));
        _addRoute(address(stock));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.RouteAlreadySet.selector, address(stock)));
        rg.addRoute(address(stock));
    }

    /// A route set to any other oracle (here through `execute`) can't be overwritten by `addRoute`.
    function test_addRouteNeverOverwritesOtherOracle() public {
        address other = makeAddr("otherOracle");
        _execute(abi.encodeCall(EulerRouter.govSetConfig, (address(stock), USD, other)));
        _approve(address(stock));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.RouteAlreadySet.selector, address(stock)));
        rg.addRoute(address(stock));
        assertEq(router.getConfiguredOracle(address(stock), USD), other);
    }

    function test_addRouteOnlyOps() public {
        _approve(address(stock));
        _expectUnauthorized(timelock, MS_OPS);
        rg.addRoute(address(stock));
    }

    // -- addWrapper -----------------------------------------------------------------------------

    function test_addWrapper() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        _approve(address(rebasing));
        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.WrapperAdded(address(w), address(rebasing));
        _addWrapper(address(w));
        assertEq(router.resolvedVaults(address(w)), address(rebasing));
    }

    /// A wrapper with the same code, from another factory, is rejected.
    function test_addWrapperRejectsNonFactoryWrapper() public {
        PoppieWrapperFactory otherFactory = new PoppieWrapperFactory(timelock, reserve);
        rebasing.mint(deployer, 1e18);
        vm.startPrank(deployer);
        rebasing.approve(address(otherFactory), 1e18);
        address w = otherFactory.createWrapper(address(rebasing), 1e18);
        vm.stopPrank();
        _approve(address(rebasing));

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.NotFactoryWrapper.selector, w));
        rg.addWrapper(w);
    }

    function test_addWrapperRejectsPlainToken() public {
        _approve(address(stock));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.NotFactoryWrapper.selector, address(stock)));
        rg.addWrapper(address(stock));
    }

    function test_addWrapperRejectsNotApprovedToken() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.TokenNotApproved.selector, address(rebasing)));
        rg.addWrapper(address(w));
    }

    function test_addWrapperIsAddOnly() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        _approve(address(rebasing));
        _addWrapper(address(w));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.WrapperAlreadyRegistered.selector, address(w)));
        rg.addWrapper(address(w));
    }

    function test_addWrapperOnlyOps() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        _approve(address(rebasing));
        _expectUnauthorized(timelock, MS_OPS);
        rg.addWrapper(address(w));
    }

    // -- addResolvedVault -----------------------------------------------------------------------

    function test_addResolvedVaultToken() public {
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));
        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.ResolvedVaultAdded(address(escrow), address(stock));
        _addResolvedVault(address(escrow));
        assertEq(router.resolvedVaults(address(escrow)), address(stock));
    }

    function test_addResolvedVaultWrapper() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        _approve(address(rebasing));
        _addWrapper(address(w));
        IEVault escrow = _createConfiguredEscrow(address(w));
        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.ResolvedVaultAdded(address(escrow), address(w));
        _addResolvedVault(address(escrow));
        assertEq(router.resolvedVaults(address(escrow)), address(w));
    }

    function test_addResolvedVaultIsAddOnly() public {
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));
        _addResolvedVault(address(escrow));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.ResolvedVaultAlreadySet.selector, address(escrow)));
        rg.addResolvedVault(address(escrow));
    }

    /// A resolved vault set any other way (here through `execute`) can't be overwritten either.
    function test_addResolvedVaultNeverOverwrites() public {
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));
        _execute(abi.encodeCall(EulerRouter.govSetResolvedVault, (address(escrow), true)));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.ResolvedVaultAlreadySet.selector, address(escrow)));
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultRejectsNonProxy() public {
        _approve(address(stock));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.NotFactoryProxy.selector, address(stock)));
        rg.addResolvedVault(address(stock));

        address eoa = makeAddr("eoa");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.NotFactoryProxy.selector, eoa));
        rg.addResolvedVault(eoa);
    }

    /// An otherwise perfect escrow from a different EVK factory is rejected.
    function test_addResolvedVaultRejectsOtherFactory() public {
        _approve(address(stock));
        GenericFactory otherFactory = new GenericFactory(admin);
        vm.prank(admin);
        otherFactory.setImplementation(evaultImpl);
        IEVault escrow = IEVault(
            otherFactory.createProxy(address(0), false, abi.encodePacked(address(stock), address(0), address(0)))
        );
        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        escrow.setGovernorAdmin(address(governor));

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.NotFactoryProxy.selector, address(escrow)));
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultRejectsUpgradeable() public {
        _approve(address(stock));
        IEVault escrow = _createVault(address(stock), address(0), address(0), true);
        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        escrow.setGovernorAdmin(address(governor));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.EscrowUpgradeable.selector, address(escrow)));
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultRejectsOracle() public {
        _approve(address(stock));
        IEVault escrow = _createVault(address(stock), address(router), address(0), false);
        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        escrow.setGovernorAdmin(address(governor));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.EscrowHasOracle.selector, address(escrow)));
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultRejectsUnitOfAccount() public {
        _approve(address(stock));
        IEVault escrow = _createVault(address(stock), address(0), USD, false);
        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        escrow.setGovernorAdmin(address(governor));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.EscrowHasUnitOfAccount.selector, address(escrow)));
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultRejectsWrongGovernor() public {
        _approve(address(stock));
        IEVault escrow = _createEscrow(address(stock));
        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        // Governance not handed over: this contract (the deployer) is still governorAdmin.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRouterGovernor.EscrowWrongGovernor.selector, address(escrow), address(this))
        );
        rg.addResolvedVault(address(escrow));

        // Renounced governance is rejected too.
        escrow.setGovernorAdmin(address(0));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRouterGovernor.EscrowWrongGovernor.selector, address(escrow), address(0))
        );
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultRejectsWrongHookTarget() public {
        _approve(address(stock));
        MockEscrowHook otherHook = new MockEscrowHook();
        _assertHookConfigRejected(address(otherHook), ESCROW_HOOKED_OPS);
        _assertHookConfigRejected(address(0), ESCROW_HOOKED_OPS);
        _assertHookConfigRejected(address(0), 0);
    }

    function test_addResolvedVaultRejectsWrongHookedOps() public {
        _approve(address(stock));
        // Missing an operation, an extra operation (withdraw must never be hooked), and nothing hooked.
        _assertHookConfigRejected(address(escrowHook), ESCROW_HOOKED_OPS & ~OP_DEPOSIT);
        _assertHookConfigRejected(address(escrowHook), ESCROW_HOOKED_OPS | OP_WITHDRAW);
        _assertHookConfigRejected(address(escrowHook), 0);
    }

    function test_addResolvedVaultRejectsNotApprovedToken() public {
        IEVault escrow = _createConfiguredEscrow(address(stock));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRouterGovernor.EscrowAssetNotAllowed.selector, address(escrow), address(stock)
            )
        );
        rg.addResolvedVault(address(escrow));
    }

    /// A factory wrapper of an approved token must be registered with `addWrapper` first.
    function test_addResolvedVaultRejectsUnregisteredWrapper() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        _approve(address(rebasing));
        IEVault escrow = _createConfiguredEscrow(address(w));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRouterGovernor.EscrowAssetNotAllowed.selector, address(escrow), address(w))
        );
        rg.addResolvedVault(address(escrow));

        _addWrapper(address(w));
        _addResolvedVault(address(escrow));
        assertEq(router.resolvedVaults(address(escrow)), address(w));
    }

    /// A vault resolved in the router that is not a factory wrapper does not count as a registered wrapper.
    function test_addResolvedVaultRejectsNonFactoryResolvedAsset() public {
        _approve(address(stock));
        IEVault inner = _createConfiguredEscrow(address(stock));
        _addResolvedVault(address(inner));
        IEVault escrow = _createConfiguredEscrow(address(inner));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoppieRouterGovernor.EscrowAssetNotAllowed.selector, address(escrow), address(inner)
            )
        );
        rg.addResolvedVault(address(escrow));
    }

    function test_addResolvedVaultOnlyOps() public {
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));
        _expectUnauthorized(timelock, MS_OPS);
        rg.addResolvedVault(address(escrow));
    }

    // -- execute --------------------------------------------------------------------------------

    function test_executeOverwritesRoute() public {
        _approve(address(stock));
        _addRoute(address(stock));
        address other = makeAddr("otherOracle");
        bytes memory data = abi.encodeCall(EulerRouter.govSetConfig, (address(stock), USD, other));

        vm.expectEmit(address(rg));
        emit IPoppieRouterGovernor.Executed(data, "");
        vm.prank(timelock);
        bytes memory result = rg.execute(data);
        assertEq(result.length, 0);
        assertEq(router.getConfiguredOracle(address(stock), USD), other);
    }

    function test_executeRemovesResolvedVault() public {
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));
        _addResolvedVault(address(escrow));
        _execute(abi.encodeCall(EulerRouter.govSetResolvedVault, (address(escrow), false)));
        assertEq(router.resolvedVaults(address(escrow)), address(0));
    }

    function test_executeReturnsResult() public {
        vm.prank(timelock);
        bytes memory result = rg.execute(abi.encodeWithSignature("governor()"));
        assertEq(abi.decode(result, (address)), address(routerGovernor));
    }

    function test_executeBubblesFailure() public {
        bytes memory data = abi.encodeCall(EulerRouter.govSetConfig, (address(stock), address(stock), address(1)));
        bytes memory reason = abi.encodeWithSelector(OracleErrors.PriceOracle_InvalidConfiguration.selector);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IPoppieRouterGovernor.ExecuteFailed.selector, reason));
        rg.execute(data);
    }

    /// Governance of the router can be moved away only through `execute`; afterwards the add functions fail.
    function test_executeTransfersGovernance() public {
        address next = makeAddr("nextGovernor");
        _execute(abi.encodeCall(Governable.transferGovernance, (next)));
        assertEq(router.governor(), next);

        _approve(address(stock));
        vm.prank(ops);
        vm.expectRevert(OracleErrors.Governance_CallerNotGovernor.selector);
        rg.addRoute(address(stock));
    }

    function test_executeOnlyAdmin() public {
        _expectUnauthorized(ops, routerGovernor.DEFAULT_ADMIN_ROLE());
        rg.execute(abi.encodeCall(Governable.transferGovernance, (ops)));
    }

    function testFuzz_noRoleCannotCall(address caller) public {
        vm.assume(caller != timelock && caller != ops);
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));

        _expectUnauthorized(caller, MS_OPS);
        rg.addRoute(address(stock));
        _expectUnauthorized(caller, MS_OPS);
        rg.addWrapper(address(stock));
        _expectUnauthorized(caller, MS_OPS);
        rg.addResolvedVault(address(escrow));
        _expectUnauthorized(caller, routerGovernor.DEFAULT_ADMIN_ROLE());
        rg.setApprovedToken(address(stock), false);
        _expectUnauthorized(caller, routerGovernor.DEFAULT_ADMIN_ROLE());
        rg.execute(abi.encodeCall(Governable.transferGovernance, (caller)));
    }

    // -- Pricing through the full listing --------------------------------------------------------

    /// Listing stage 2 for a plain token: escrow shares are priced escrow -> token -> adapter.
    function test_pricingEscrowToToken() public {
        _approve(address(stock));
        IEVault escrow = _createConfiguredEscrow(address(stock));
        _listOnOracle(address(stock));
        _addRoute(address(stock));
        _addResolvedVault(address(escrow));
        _goLive(address(stock), 100e18);

        uint256 shares = 3e18;
        uint256 expected = adapter.getQuote(escrow.convertToAssets(shares), address(stock), USD);
        assertGt(expected, 0);
        assertEq(router.getQuote(shares, address(escrow), USD), expected);
    }

    /// Listing stage 2 for a wrapped token: escrow shares are priced escrow -> wrapper -> token -> adapter.
    function test_pricingEscrowToWrapperToToken() public {
        PoppieBalanceWrapper w = _createWrapper(address(rebasing), 1e18);
        _approve(address(rebasing));
        IEVault escrow = _createConfiguredEscrow(address(w));
        _listOnOracle(address(rebasing));
        _addWrapper(address(w));
        _addRoute(address(rebasing));
        _addResolvedVault(address(escrow));
        _goLive(address(rebasing), 50e18);

        uint256 shares = 7e24;
        uint256 tokens = IERC4626(address(w)).convertToAssets(escrow.convertToAssets(shares));
        uint256 expected = adapter.getQuote(tokens, address(rebasing), USD);
        assertGt(expected, 0);
        assertEq(router.getQuote(shares, address(escrow), USD), expected);
    }

    // -- Helpers --------------------------------------------------------------------------------

    function _execute(bytes memory data) internal {
        vm.prank(timelock);
        rg.execute(data);
    }

    function _expectUnauthorized(address caller, bytes32 role) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
    }

    function _assertHookConfigRejected(address target, uint32 ops_) internal {
        IEVault escrow = _createEscrow(address(stock));
        escrow.setHookConfig(target, ops_);
        escrow.setGovernorAdmin(address(governor));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IPoppieRouterGovernor.EscrowWrongHookConfig.selector, address(escrow), target, ops_)
        );
        rg.addResolvedVault(address(escrow));
    }
}
