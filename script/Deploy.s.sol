// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IGovernance} from "evk/EVault/IEVault.sol";
import {CFG_DONT_SOCIALIZE_DEBT} from "evk/EVault/shared/Constants.sol";
import {IRMLinearKink} from "evk/InterestRateModels/IRMLinearKink.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {GovernorAccessControl} from "evk-periphery/Governor/GovernorAccessControl.sol";

import {PoppieEulerOracle} from "../src/oracle/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/oracle/PoppieEulerAdapter.sol";
import {PoppieFeeRouter} from "../src/fee/PoppieFeeRouter.sol";
import {PoppieHubHook} from "../src/hooks/PoppieHubHook.sol";
import {PoppieEscrowHook} from "../src/hooks/PoppieEscrowHook.sol";
import {PoppieWrapperFactory} from "../src/wrapper/PoppieWrapperFactory.sol";
import {PoppieRouterGovernor} from "../src/governance/PoppieRouterGovernor.sol";
import {PoppieRiskSteward} from "../src/steward/PoppieRiskSteward.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieRiskSteward} from "../src/interfaces/IPoppieRiskSteward.sol";
import {HUB_HOOKED_OPS} from "../src/hooks/HookOps.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_GUARD} from "../src/access/Roles.sol";

import {ScriptBase} from "./lib/ScriptBase.sol";
import {DeployConfig, HubParams, EarnParams, Deployment} from "./lib/Types.sol";
import {IEulerEarnFactoryMinimal, IEulerEarnMinimal, IKinkIRMFactory} from "./lib/ExternalInterfaces.sol";

/// @title Deploy
/// @notice Deploys and wires the whole Poppie stack against Euler core at the configured addresses (V2_PLAN
/// section 7, CONTRACT_SPEC section 2):
/// timelock (48h; proposer + executor MS_ADMIN, canceller MS_OPS) -> Euler Governor -> oracle + adapter -> hub hook +
/// fee router (immutable pair, CREATE-address precompute asserted) -> wrapper factory (dividend recipient = reserve)
/// -> escrow hook -> EulerRouter + router governor -> risk steward -> 4 hubs (IRM, interest fee, max liquidation
/// discount, CFG_DONT_SOCIALIZE_DEBT, non-zero fee receiver, hook, caps, governor hand-off; registered in the hook
/// and the steward; origination fee and cap ceilings) -> Earn vaults (optional) -> roles (K_LOOSEN to MS_OPS for
/// phase 1) -> DEFAULT_ADMIN_ROLE to the timelock -> deployer renounces every role.
///
/// @dev Simulation, anvil or fork only. Never `--broadcast` to a live network from an agent: the launch is POP-18
/// (human only). Usage (simulation): `forge script script/Deploy.s.sol --sig "run(string)" config/deploy.json`.
contract Deploy is ScriptBase {
    address internal constant USD = address(840);

    /// @dev Simulate with the default sender.
    function run(string memory configPath) external returns (Deployment memory d) {
        DeployConfig memory cfg = loadDeployConfig(configPath);
        d = deploy(cfg, msg.sender);
        string memory json = deploymentJson(d);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    /// @notice Deploy everything as `deployer`. Calls and creations are broadcast as `deployer` (in a test this
    /// behaves like a prank that also sets the creator).
    function deploy(DeployConfig memory cfg, address deployer) public returns (Deployment memory d) {
        _validate(cfg);
        d.deployer = deployer;
        vm.startBroadcast(deployer);

        // 1. Timelock: proposer and executor MS_ADMIN; MS_OPS can cancel. The deployer's admin is renounced below.
        address[] memory proposers = new address[](1);
        proposers[0] = cfg.msAdmin;
        TimelockController timelock = new TimelockController(cfg.timelockDelay, proposers, proposers, deployer);
        timelock.grantRole(timelock.CANCELLER_ROLE(), cfg.msOps);
        d.timelock = address(timelock);

        // 2. Euler Governor (governorAdmin of every hub and escrow).
        GovernorAccessControl governor = new GovernorAccessControl(cfg.evc, deployer);
        d.governor = address(governor);

        // 3. Oracle + adapter.
        d.oracle = address(new PoppieEulerOracle(deployer));
        d.adapter = address(new PoppieEulerAdapter(IPoppieEulerOracle(d.oracle)));

        // 4. Hook <-> fee router: both immutable. The hook is created first with the router's CREATE address.
        address predictedRouter = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        d.hubHook = address(new PoppieHubHook(deployer, cfg.evc, predictedRouter));
        d.feeRouter = address(new PoppieFeeRouter(deployer, cfg.evc, d.hubHook));
        require(d.feeRouter == predictedRouter, "Deploy: fee router address mismatch");
        require(PoppieHubHook(d.hubHook).feeRouter() == d.feeRouter, "Deploy: hook -> router");
        require(PoppieFeeRouter(d.feeRouter).hook() == d.hubHook, "Deploy: router -> hook");

        // 5. Wrapper factory and escrow hook.
        d.wrapperFactory = address(new PoppieWrapperFactory(deployer, cfg.reserveSafe));
        d.escrowHook = address(new PoppieEscrowHook(deployer, cfg.evc, d.oracle, d.wrapperFactory));

        // 6. EulerRouter (USDC/USD route), then its governance to the router governor.
        EulerRouter router = new EulerRouter(cfg.evc, deployer);
        d.router = address(router);
        router.govSetConfig(cfg.usdc, USD, cfg.usdcUsdOracle);
        d.routerGovernor = address(
            new PoppieRouterGovernor(
                deployer, d.router, d.adapter, d.wrapperFactory, cfg.eVaultFactory, d.governor, d.escrowHook
            )
        );
        router.transferGovernance(d.routerGovernor);

        // 7. Steward, with the setLTV / setCaps selector roles on the Governor.
        d.steward = address(new PoppieRiskSteward(deployer, d.governor));
        governor.grantRole(bytes32(IGovernance.setLTV.selector), d.steward);
        governor.grantRole(bytes32(IGovernance.setCaps.selector), d.steward);

        // Temporary setup roles for the deployer (renounced below).
        PoppieFeeRouter(d.feeRouter).grantRole(MS_OPS, deployer);
        PoppieRiskSteward(d.steward).grantRole(MS_OPS, deployer);

        // 8. Hubs.
        d.hubs = new address[](cfg.hubs.length);
        d.irms = new address[](cfg.hubs.length);
        for (uint256 i; i < cfg.hubs.length; ++i) {
            (d.hubs[i], d.irms[i]) = _deployHub(cfg, d, cfg.hubs[i]);
        }

        // 9. Earn vaults (optional; needs the canonical Euler Earn factory).
        d.earns = new address[](cfg.eulerEarnFactory == address(0) ? 0 : cfg.earns.length);
        for (uint256 i; i < d.earns.length; ++i) {
            d.earns[i] = _deployEarn(cfg, d, cfg.earns[i]);
        }

        // 10. Roles, then hand-off.
        _grantRoles(cfg, d);
        _handOff(d, deployer, governor, timelock);
        vm.stopBroadcast();

        console.log("Poppie deployed. timelock", d.timelock);
    }

    function _validate(DeployConfig memory cfg) internal pure {
        require(
            cfg.evc != address(0) && cfg.eVaultFactory != address(0) && cfg.usdc != address(0)
                && cfg.usdcUsdOracle != address(0),
            "Deploy: Euler core addresses"
        );
        require(
            cfg.msAdmin != address(0) && cfg.msOps != address(0) && cfg.reserveSafe != address(0)
                && cfg.kPrice != address(0) && cfg.kConfirm != address(0) && cfg.kTighten != address(0)
                && cfg.kGuard != address(0),
            "Deploy: role holders"
        );
        require(cfg.timelockDelay >= 48 hours, "Deploy: timelock delay < 48h");
        require(cfg.hubs.length != 0, "Deploy: no hubs");
        for (uint256 i; i < cfg.hubs.length; ++i) {
            require(cfg.hubs[i].feeReceiver != address(0), "Deploy: zero fee receiver");
            require(cfg.hubs[i].band <= 3, "Deploy: band");
            require(cfg.hubs[i].originationFeeBps <= 100, "Deploy: origination fee");
        }
    }

    function _deployHub(DeployConfig memory cfg, Deployment memory d, HubParams memory p)
        internal
        returns (address hubAddr, address irm)
    {
        irm = cfg.kinkIrmFactory == address(0)
            ? address(new IRMLinearKink(p.irmBaseRate, p.irmSlope1, p.irmSlope2, p.irmKink))
            : IKinkIRMFactory(cfg.kinkIrmFactory).deploy(p.irmBaseRate, p.irmSlope1, p.irmSlope2, p.irmKink);

        IEVault hub = IEVault(
            GenericFactory(cfg.eVaultFactory).createProxy(address(0), true, abi.encodePacked(cfg.usdc, d.router, USD))
        );
        hubAddr = address(hub);
        hub.setInterestRateModel(irm);
        hub.setInterestFee(p.interestFee);
        hub.setMaxLiquidationDiscount(p.maxLiquidationDiscount);
        hub.setFeeReceiver(p.feeReceiver);
        hub.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT);
        hub.setCaps(encodeCap(p.supplyCap), encodeCap(p.borrowCap));
        hub.setHookConfig(d.hubHook, HUB_HOOKED_OPS);
        hub.setGovernorAdmin(d.governor);

        PoppieHubHook(d.hubHook).registerHub(hubAddr);
        PoppieRiskSteward(d.steward).addHub(hubAddr, IPoppieRiskSteward.RiskClass(p.band));
        PoppieFeeRouter(d.feeRouter).setFeeBps(hubAddr, p.originationFeeBps);
        IPoppieRiskSteward.CapCeilingChange[] memory c = new IPoppieRiskSteward.CapCeilingChange[](1);
        c[0] =
            IPoppieRiskSteward.CapCeilingChange(hubAddr, encodeCap(p.supplyCapCeiling), encodeCap(p.borrowCapCeiling));
        PoppieRiskSteward(d.steward).setCapCeiling(c);
    }

    /// @dev Earn vault: created with timelock 0 so the initial caps apply at once, then curator / allocator / Earn
    /// timelock set, and ownership offered to the Poppie timelock (Ownable2Step: the timelock must accept, a
    /// timelocked MS_ADMIN action after launch). Hubs Earn's factory does not accept (`isStrategyAllowed`) are
    /// skipped and logged; ConfigCheck reports them.
    function _deployEarn(DeployConfig memory cfg, Deployment memory d, EarnParams memory p)
        internal
        returns (address earnAddr)
    {
        IEulerEarnFactoryMinimal f = IEulerEarnFactoryMinimal(cfg.eulerEarnFactory);
        IEulerEarnMinimal earn = f.createEulerEarn(d.deployer, 0, cfg.usdc, p.name, p.symbol, keccak256(bytes(p.name)));
        earnAddr = address(earn);
        uint256 n;
        IERC4626[] memory queue = new IERC4626[](p.hubIndexes.length);
        for (uint256 i; i < p.hubIndexes.length; ++i) {
            address hub = d.hubs[p.hubIndexes[i]];
            if (!f.isStrategyAllowed(hub)) {
                console.log("Earn factory rejects hub (perspective):", hub);
                continue;
            }
            earn.submitCap(IERC4626(hub), p.capPerHub);
            earn.acceptCap(IERC4626(hub));
            queue[n++] = IERC4626(hub);
        }
        assembly {
            mstore(queue, n)
        }
        if (n != 0) earn.setSupplyQueue(queue);
        if (p.timelock != 0) earn.submitTimelock(p.timelock);
        earn.setCurator(cfg.msOps);
        if (cfg.kAlloc != address(0)) earn.setIsAllocator(cfg.kAlloc, true);
        earn.transferOwnership(d.timelock);
    }

    function _grantRoles(DeployConfig memory cfg, Deployment memory d) internal {
        PoppieEulerOracle(d.oracle).grantRole(MS_OPS, cfg.msOps);
        PoppieEulerOracle(d.oracle).grantRole(K_PRICE, cfg.kPrice);
        PoppieEulerOracle(d.oracle).grantRole(K_CONFIRM, cfg.kConfirm);
        PoppieHubHook(d.hubHook).grantRole(MS_OPS, cfg.msOps);
        PoppieHubHook(d.hubHook).grantRole(K_GUARD, cfg.kGuard);
        PoppieEscrowHook(d.escrowHook).grantRole(MS_OPS, cfg.msOps);
        PoppieEscrowHook(d.escrowHook).grantRole(K_GUARD, cfg.kGuard);
        PoppieFeeRouter(d.feeRouter).grantRole(MS_OPS, cfg.msOps);
        PoppieRouterGovernor(d.routerGovernor).grantRole(MS_OPS, cfg.msOps);
        PoppieRiskSteward(d.steward).grantRole(MS_OPS, cfg.msOps);
        PoppieRiskSteward(d.steward).grantRole(K_TIGHTEN, cfg.kTighten);
        PoppieRiskSteward(d.steward).grantRole(K_LOOSEN, cfg.msOps); // phase 1: MS_OPS holds K_LOOSEN
    }

    /// @dev DEFAULT_ADMIN_ROLE to the timelock on every contract (and the Governor's wildcard, so the timelock can
    /// change any other vault setting), then the deployer renounces everything it holds.
    function _handOff(Deployment memory d, address deployer, GovernorAccessControl governor, TimelockController tl)
        internal
    {
        address[7] memory poppie =
            [d.oracle, d.hubHook, d.feeRouter, d.escrowHook, d.wrapperFactory, d.routerGovernor, d.steward];
        bytes32 admin = 0x00;
        for (uint256 i; i < poppie.length; ++i) {
            PoppieRiskSteward(poppie[i]).grantRole(admin, d.timelock);
        }
        governor.grantRole(admin, d.timelock);
        governor.grantRole(governor.WILD_CARD(), d.timelock);

        PoppieFeeRouter(d.feeRouter).renounceRole(MS_OPS, deployer);
        PoppieRiskSteward(d.steward).renounceRole(MS_OPS, deployer);
        for (uint256 i; i < poppie.length; ++i) {
            PoppieRiskSteward(poppie[i]).renounceRole(admin, deployer);
        }
        governor.renounceRole(admin, deployer);
        tl.renounceRole(admin, deployer);
    }
}
