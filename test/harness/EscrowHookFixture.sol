// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEVault} from "evk/EVault/IEVault.sol";

import {PoppieEscrowHook} from "../../src/hooks/PoppieEscrowHook.sol";
import {ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS, K_GUARD} from "../../src/access/Roles.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";

import {HubHookFixture} from "./HubHookFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStateOracle, MockWrapperFactory, MockWrapper} from "../mocks/MockEscrowDeps.sol";

/// @notice `HubHookFixture` plus the real `PoppieEscrowHook` installed on its escrow vault, and a second escrow
/// vault whose `asset()` is a wrapper. The oracle and wrapper factory are mocks consumed through the foundation
/// interfaces. Escrow creation order follows the listing flow: seed deposits first, then the hook config.
abstract contract EscrowHookFixture is HubHookFixture {
    PoppieEscrowHook internal escrowHook;
    MockStateOracle internal stateOracle;
    MockWrapperFactory internal wrapperFactory;

    /// @dev Balance-changing token held through a wrapper.
    MockERC20 internal rebasing;
    MockWrapper internal wrapper;
    /// @dev Escrow vault whose `asset()` is `wrapper`.
    IEVault internal wrappedEscrow;

    address internal depositor = makeAddr("depositor");

    function setUp() public virtual override {
        super.setUp();

        stateOracle = new MockStateOracle();
        wrapperFactory = new MockWrapperFactory();
        escrowHook = new PoppieEscrowHook(admin, address(evc), address(stateOracle), address(wrapperFactory));

        vm.startPrank(admin);
        escrowHook.grantRole(MS_OPS, ops);
        escrowHook.grantRole(K_GUARD, guard);
        vm.stopPrank();

        rebasing = new MockERC20("Rebasing Stock", "rSTK", 18);
        wrapper = new MockWrapper(rebasing);
        wrapperFactory.register(address(rebasing), address(wrapper));
        wrappedEscrow = _createEscrow(address(wrapper));

        // Seed deposits happen before the hook config (listing flow), so they need no oracle state.
        _seedWrapped(depositor, 100e18);

        // The oracle lists underlying tokens only, never the wrapper.
        stateOracle.setState(address(stock), IPoppieEulerOracle.PriceState.Live);
        stateOracle.setState(address(rebasing), IPoppieEulerOracle.PriceState.Live);

        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        wrappedEscrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);

        // Fund the depositor for deposits after the hook is live.
        stock.mint(depositor, 1_000e18);
        vm.prank(depositor);
        stock.approve(address(escrow), type(uint256).max);
    }

    function _seedWrapped(address who, uint256 amount) internal {
        rebasing.mint(who, amount);
        vm.startPrank(who);
        rebasing.approve(address(wrapper), amount);
        wrapper.deposit(amount, who);
        wrapper.approve(address(wrappedEscrow), type(uint256).max);
        wrappedEscrow.deposit(amount / 2, who);
        vm.stopPrank();
    }

    function _setState(address token, IPoppieEulerOracle.PriceState s) internal {
        stateOracle.setState(token, s);
    }

    function _vaults(address v) internal pure returns (address[] memory vs) {
        vs = new address[](1);
        vs[0] = v;
    }

    function _vaults(address v0, address v1) internal pure returns (address[] memory vs) {
        vs = new address[](2);
        vs[0] = v0;
        vs[1] = v1;
    }

    function _pauseDeposits(address vault, uint40 duration) internal {
        vm.prank(guard);
        escrowHook.pauseDeposits(_vaults(vault), duration);
    }
}
