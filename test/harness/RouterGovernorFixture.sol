// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";

import {PoppieRouterGovernor} from "../../src/governance/PoppieRouterGovernor.sol";
import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/oracle/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS, K_PRICE, K_CONFIRM} from "../../src/access/Roles.sol";

import {MockEscrowHook} from "../mocks/MockEscrowHook.sol";
import {WrapperFixture} from "./WrapperFixture.sol";

/// @notice `PoppieRouterGovernor` on top of the local Euler stack and the wrapper factory, with the oracle and
/// adapter it routes to. The router's governor is handed to the router governor, as in the deploy script. The
/// escrow hook is `MockEscrowHook` until `PoppieEscrowHook` lands.
abstract contract RouterGovernorFixture is WrapperFixture {
    /// @dev The MS_OPS Safe.
    address internal ops;
    address internal keeper;
    address internal confirmer;

    PoppieEulerOracle internal oracle;
    PoppieEulerAdapter internal adapter;
    MockEscrowHook internal escrowHook;
    PoppieRouterGovernor internal routerGovernor;

    function setUp() public virtual override {
        super.setUp();
        ops = makeAddr("ops");
        keeper = makeAddr("keeper");
        confirmer = makeAddr("confirmer");

        oracle = new PoppieEulerOracle(timelock);
        adapter = new PoppieEulerAdapter(IPoppieEulerOracle(address(oracle)));
        escrowHook = new MockEscrowHook();

        routerGovernor = new PoppieRouterGovernor(
            timelock,
            address(router),
            address(adapter),
            address(wrapperFactory),
            address(factory),
            address(governor),
            address(escrowHook)
        );
        router.transferGovernance(address(routerGovernor));

        vm.startPrank(timelock);
        routerGovernor.grantRole(MS_OPS, ops);
        oracle.grantRole(MS_OPS, ops);
        oracle.grantRole(K_PRICE, keeper);
        oracle.grantRole(K_CONFIRM, confirmer);
        vm.stopPrank();
    }

    // -- Listing helpers ----------------------------------------------------------------------------

    function _approve(address token) internal {
        vm.prank(timelock);
        routerGovernor.setApprovedToken(token, true);
    }

    /// @notice An escrow vault for `asset` as the deployer key leaves it: escrow hook config set and governance
    /// handed to the Poppie Governor.
    function _createConfiguredEscrow(address asset) internal returns (IEVault vault) {
        vault = _createEscrow(asset);
        vault.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        vault.setGovernorAdmin(address(governor));
    }

    function _addRoute(address token) internal {
        vm.prank(ops);
        routerGovernor.addRoute(token);
    }

    function _addWrapper(address wrapper) internal {
        vm.prank(ops);
        routerGovernor.addWrapper(wrapper);
    }

    function _addResolvedVault(address escrow) internal {
        vm.prank(ops);
        routerGovernor.addResolvedVault(escrow);
    }

    // -- Oracle helpers -------------------------------------------------------------------------------

    function _listOnOracle(address token) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        IPoppieEulerOracle.PriceClass[] memory c = new IPoppieEulerOracle.PriceClass[](1);
        c[0] = IPoppieEulerOracle.PriceClass.BlueChip;
        vm.prank(ops);
        oracle.listAssets(t, c);
    }

    /// @notice Take `token` live at `price` (18-decimal USD per whole token): push, then confirm.
    function _goLive(address token, uint128 price) internal {
        address[] memory a = new address[](1);
        a[0] = token;
        uint128[] memory p = new uint128[](1);
        p[0] = price;
        vm.prank(keeper);
        oracle.keeperPushPrices(a, p);
        vm.prank(confirmer);
        oracle.confirm(token, price);
    }
}
