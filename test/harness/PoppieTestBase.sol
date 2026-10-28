// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {ProtocolConfig} from "evk/ProtocolConfig/ProtocolConfig.sol";
import {SequenceRegistry} from "evk/SequenceRegistry/SequenceRegistry.sol";
import {Base} from "evk/EVault/shared/Base.sol";
import {Dispatch} from "evk/EVault/Dispatch.sol";
import {EVault} from "evk/EVault/EVault.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {Initialize} from "evk/EVault/modules/Initialize.sol";
import {Token} from "evk/EVault/modules/Token.sol";
import {Vault} from "evk/EVault/modules/Vault.sol";
import {Borrowing} from "evk/EVault/modules/Borrowing.sol";
import {Liquidation} from "evk/EVault/modules/Liquidation.sol";
import {RiskManager} from "evk/EVault/modules/RiskManager.sol";
import {BalanceForwarder} from "evk/EVault/modules/BalanceForwarder.sol";
import {Governance} from "evk/EVault/modules/Governance.sol";

import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {GovernorAccessControl} from "evk-periphery/Governor/GovernorAccessControl.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Local Euler V2 stack for EVK-level tests, no fork: EVC, EVK factory and implementation (with all
/// modules), EulerRouter, an Euler Governor, mock USDC and a mock equity token.
/// @dev Later tickets extend this contract and deploy their Poppie contracts on top. Defaults a test can
/// change: the router governor is this contract (swap in PoppieRouterGovernor), vaults are created with this
/// contract as `governorAdmin` (hand over to `governor` as the listing flow does).
abstract contract PoppieTestBase is Test {
    /// @dev ISO 4217 code for USD, the unit of account on every hub.
    address internal constant USD = address(840);

    address internal admin;
    address internal protocolFeeReceiver;

    EthereumVaultConnector internal evc;
    ProtocolConfig internal protocolConfig;
    SequenceRegistry internal sequenceRegistry;
    GenericFactory internal factory;
    address internal evaultImpl;
    EulerRouter internal router;
    GovernorAccessControl internal governor;

    /// @dev 6 decimals, like canonical USDC.
    MockERC20 internal usdc;
    /// @dev 18 decimals, stands in for a tokenized equity.
    MockERC20 internal stock;

    function setUp() public virtual {
        admin = makeAddr("admin");
        protocolFeeReceiver = makeAddr("protocolFeeReceiver");

        evc = new EthereumVaultConnector();
        protocolConfig = new ProtocolConfig(admin, protocolFeeReceiver);
        sequenceRegistry = new SequenceRegistry();
        factory = new GenericFactory(admin);

        // Balance tracker and Permit2 are not deployed: balance forwarding is never enabled, and a zero permit2
        // makes EVK pull assets with a plain ERC20 transferFrom. (A codeless non-zero permit2 address would make
        // EVK's permit2 call "succeed" without moving any tokens.)
        Base.Integrations memory integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(protocolConfig),
            sequenceRegistry: address(sequenceRegistry),
            balanceTracker: address(0),
            permit2: address(0)
        });
        Dispatch.DeployedModules memory modules = Dispatch.DeployedModules({
            initialize: address(new Initialize(integrations)),
            token: address(new Token(integrations)),
            vault: address(new Vault(integrations)),
            borrowing: address(new Borrowing(integrations)),
            liquidation: address(new Liquidation(integrations)),
            riskManager: address(new RiskManager(integrations)),
            balanceForwarder: address(new BalanceForwarder(integrations)),
            governance: address(new Governance(integrations))
        });
        evaultImpl = address(new EVault(integrations, modules));
        vm.prank(admin);
        factory.setImplementation(evaultImpl);

        router = new EulerRouter(address(evc), address(this));
        governor = new GovernorAccessControl(address(evc), admin);

        usdc = new MockERC20("Mock USDC", "USDC", 6);
        stock = new MockERC20("Mock Stock", "mSTK", 18);
    }

    /// @notice Create an EVK vault through the factory. `governorAdmin` is this contract.
    function _createVault(address asset, address oracle, address unitOfAccount, bool upgradeable)
        internal
        returns (IEVault vault)
    {
        vault = IEVault(factory.createProxy(address(0), upgradeable, abi.encodePacked(asset, oracle, unitOfAccount)));
        // A fresh EVK vault hooks every operation with no hook target, which disables all of them until the
        // hook config is set. Clear it so the vault is usable; tests install real hooks with setHookConfig.
        vault.setHookConfig(address(0), 0);
    }

    /// @notice A hub: a USDC borrow vault priced by the router, unit of account USD.
    function _createHub() internal returns (IEVault) {
        return _createVault(address(usdc), address(router), USD, true);
    }

    /// @notice An escrow vault: no oracle, no unit of account, non-upgradeable factory proxy.
    function _createEscrow(address asset) internal returns (IEVault) {
        return _createVault(asset, address(0), address(0), false);
    }
}
