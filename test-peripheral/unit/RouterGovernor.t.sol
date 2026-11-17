// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {Errors} from "euler-price-oracle/lib/Errors.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockFactory, MockVault} from "../lib/Mocks.sol";
import {RouterGovernor} from "../../src/peripheral/RouterGovernor.sol";
import {IEulerRouterSubset} from "../../src/peripheral/interfaces/IEulerRouterSubset.sol";
import {IAdapterSubset} from "../../src/peripheral/interfaces/IAdapterSubset.sol";
import {IFactorySubset} from "../../src/peripheral/interfaces/IFactoryAndAssetSubset.sol";

abstract contract P5Base is Test {
    address internal constant USD = address(840);

    PoppieEulerOracle internal oracle;
    PoppieEulerAdapter internal adapter;
    EulerRouter internal router;
    MockFactory internal factory;
    RouterGovernor internal p5;
    address internal ops = makeAddr("msOps");
    address internal timelock = makeAddr("timelock");
    address internal otherOracle = makeAddr("otherOracle");

    address internal X; // registered
    address internal Y; // registered
    address internal Z; // configured on oracle, not registered on adapter
    MockVault internal escrowX; // factory vault over X

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        X = address(new MockERC20("X", "X", 18));
        Y = address(new MockERC20("Y", "Y", 6));
        Z = address(new MockERC20("Z", "Z", 18));
        oracle = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory as_ = new address[](3);
        (as_[0], as_[1], as_[2]) = (X, Y, Z);
        uint16[] memory cb = new uint16[](3);
        for (uint256 i; i < 3; ++i) cb[i] = 1000;
        oracle.configureAssets(as_, cb, cb);
        for (uint256 i; i < 3; ++i) oracle.adminSetPrice(as_[i], 100e18);
        adapter = new PoppieEulerAdapter(address(oracle), address(this), USD, 18);
        adapter.registerBase(X, 18);
        adapter.registerBase(Y, 6);

        router = new EulerRouter(address(new EthereumVaultConnector()), address(this));
        factory = new MockFactory();
        escrowX = new MockVault(X);
        factory.set(address(escrowX), true);
        p5 = new RouterGovernor(
            IEulerRouterSubset(address(router)), IAdapterSubset(address(adapter)), IFactorySubset(address(factory)), ops, timelock
        );
        router.transferGovernance(address(p5)); // one-step: no accept needed
    }

    function _route(address b) internal view returns (address) {
        return router.getConfiguredOracle(b, USD);
    }
}

contract RouterGovernorUnitTest is P5Base {
    function test_quoteFromAdapter() public view {
        assertEq(p5.quote(), USD);
        assertEq(router.governor(), address(p5));
    }

    function test_addRoute_endToEnd() public {
        vm.prank(ops);
        p5.addRoute(X);
        assertEq(_route(X), address(adapter));
        assertEq(router.getQuote(2e18, X, USD), 200e18);
    }

    function test_addRoute_onlyOps() public {
        vm.expectRevert(RouterGovernor.Unauthorized.selector);
        p5.addRoute(X);
    }

    function test_addRoute_unregistered_reverts() public {
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.BaseNotRegistered.selector, Z));
        p5.addRoute(Z);
    }

    function test_addRoute_existing_reverts() public {
        vm.startPrank(ops);
        p5.addRoute(X);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.RouteExists.selector, X));
        p5.addRoute(X);
        vm.stopPrank();
    }

    function test_addRoute_existingOtherOracle_reverts() public {
        vm.prank(timelock);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (Y, USD, otherOracle)));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.RouteExists.selector, Y));
        p5.addRoute(Y);
        assertEq(_route(Y), otherOracle);
    }

    function test_addRoute_shadowingResolvedVault_reverts() public {
        // register the escrow itself as an adapter base, then try to route it directly
        oracle.configureAssets(_a(address(escrowX)), _u(1000), _u(1000));
        adapter.registerBase(address(escrowX), 18);
        vm.startPrank(ops);
        p5.addRoute(X);
        p5.addResolvedVault(address(escrowX));
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.IsResolvedVault.selector, address(escrowX)));
        p5.addRoute(address(escrowX));
        vm.stopPrank();
    }

    function test_addResolvedVault_ok() public {
        vm.startPrank(ops);
        p5.addRoute(X);
        p5.addResolvedVault(address(escrowX));
        vm.stopPrank();
        assertEq(router.resolvedVaults(address(escrowX)), X);
    }

    function test_addResolvedVault_twice_reverts() public {
        vm.startPrank(ops);
        p5.addRoute(X);
        p5.addResolvedVault(address(escrowX));
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.IsResolvedVault.selector, address(escrowX)));
        p5.addResolvedVault(address(escrowX));
        vm.stopPrank();
    }

    function test_addResolvedVault_hasDirectRoute_reverts() public {
        vm.prank(ops);
        p5.addRoute(X);
        vm.prank(timelock);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (address(escrowX), USD, otherOracle)));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.RouteExists.selector, address(escrowX)));
        p5.addResolvedVault(address(escrowX));
    }

    function test_addResolvedVault_notFactory_reverts() public {
        MockVault rogue = new MockVault(X);
        vm.prank(ops);
        p5.addRoute(X);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.NotFactoryVault.selector, address(rogue)));
        p5.addResolvedVault(address(rogue));
    }

    function test_addResolvedVault_assetNotRouted_reverts() public {
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.AssetNotRouted.selector, address(escrowX), X));
        p5.addResolvedVault(address(escrowX));
        // routed, but to another oracle
        vm.prank(timelock);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (X, USD, otherOracle)));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RouterGovernor.AssetNotRouted.selector, address(escrowX), X));
        p5.addResolvedVault(address(escrowX));
    }

    function test_addResolvedVault_onlyOps() public {
        vm.expectRevert(RouterGovernor.Unauthorized.selector);
        p5.addResolvedVault(address(escrowX));
    }

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _u(uint16 x) internal pure returns (uint16[] memory r) {
        r = new uint16[](1);
        r[0] = x;
    }
}

contract RouterGovernorFuzzTest is P5Base {
    address[] internal pool;
    uint256 internal oks;

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _u(uint16 x) internal pure returns (uint16[] memory r) {
        r = new uint16[](1);
        r[0] = x;
    }

    function setUp() public override {
        super.setUp();
        // pre-existing entries ops must never change
        vm.startPrank(timelock);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (Y, USD, otherOracle)));
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (X, USD, address(adapter))));
        vm.stopPrank();
        address W = address(new MockERC20("W", "W", 18)); // registered, unrouted: addRoute can succeed
        oracle.configureAssets(_a(W), _u(1000), _u(1000));
        adapter.registerBase(W, 18);
        MockVault escrowY = new MockVault(Y);
        MockVault escrowZ = new MockVault(Z);
        MockVault escrowW = new MockVault(W);
        factory.set(address(escrowY), true);
        factory.set(address(escrowZ), true);
        factory.set(address(escrowW), true);
        pool = [X, Y, Z, W, address(escrowX), address(escrowY), address(escrowZ), address(escrowW), makeAddr("rand")];
        oks = 0;
    }

    function _snapshot() internal view returns (address[] memory routes, address[] memory resolved) {
        routes = new address[](pool.length);
        resolved = new address[](pool.length);
        for (uint256 i; i < pool.length; ++i) {
            routes[i] = _route(pool[i]);
            resolved[i] = router.resolvedVaults(pool[i]);
        }
    }

    function testFuzz_opsNeverChangesExistingEntries(uint8[16] memory picks, bool[16] memory kind) public {
        for (uint256 s; s < 16; ++s) {
            (address[] memory r0, address[] memory v0) = _snapshot();
            address t = pool[picks[s] % pool.length];
            vm.prank(ops);
            if (kind[s]) {
                try p5.addRoute(t) { oks++; } catch {}
            } else {
                try p5.addResolvedVault(t) { oks++; } catch {}
            }
            (address[] memory r1, address[] memory v1) = _snapshot();
            for (uint256 i; i < pool.length; ++i) {
                if (r0[i] != address(0)) assertEq(r1[i], r0[i], "route changed");
                if (v0[i] != address(0)) assertEq(v1[i], v0[i], "resolved vault changed");
                if (r1[i] != r0[i]) assertEq(r1[i], address(adapter), "new route not to adapter");
                assertFalse(r1[i] != address(0) && v1[i] != address(0), "route shadows resolved vault");
            }
        }
        assertLe(oks, 3); // at most: route W, resolve escrowX, resolve escrowW
    }

    function test_fuzzPoolAllowsSuccesses() public {
        vm.startPrank(ops);
        p5.addRoute(pool[3]); // W
        p5.addResolvedVault(pool[7]); // escrowW
        p5.addResolvedVault(pool[4]); // escrowX
        vm.stopPrank();
    }

    function test_timelockOverwrite_andDelete() public {
        vm.startPrank(timelock);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (X, USD, otherOracle)));
        assertEq(_route(X), otherOracle);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (X, USD, address(0))));
        assertEq(_route(X), address(0));
        p5.execute(abi.encodeCall(EulerRouter.govSetFallbackOracle, (otherOracle)));
        assertEq(router.fallbackOracle(), otherOracle);
        vm.stopPrank();
    }

    function test_nonTimelockExecute_reverts() public {
        bytes memory d = abi.encodeCall(EulerRouter.govSetConfig, (X, USD, otherOracle));
        vm.prank(ops);
        vm.expectRevert(RouterGovernor.Unauthorized.selector);
        p5.execute(d);
        vm.expectRevert(RouterGovernor.Unauthorized.selector);
        p5.execute(d);
    }

    function test_executeBubblesRouterError() public {
        vm.prank(timelock);
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        p5.execute(abi.encodeCall(EulerRouter.govSetConfig, (USD, USD, otherOracle)));
    }

    function test_exit_transferGovernance() public {
        vm.prank(timelock);
        p5.execute(abi.encodeWithSignature("transferGovernance(address)", ops));
        assertEq(router.governor(), ops);
        adapter.registerBase(Z, 18);
        vm.prank(ops);
        vm.expectRevert(Errors.Governance_CallerNotGovernor.selector);
        p5.addRoute(Z); // passes P5's checks, but P5 no longer governs
        vm.prank(ops);
        router.govSetConfig(Z, USD, otherOracle);
    }
}
