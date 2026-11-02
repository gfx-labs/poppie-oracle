// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/console.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IGovernance} from "evk/EVault/IEVault.sol";
import {CFG_DONT_SOCIALIZE_DEBT} from "evk/EVault/shared/Constants.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

import {PoppieEulerOracle} from "../src/oracle/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../src/oracle/PoppieEulerAdapter.sol";
import {PoppieFeeRouter} from "../src/fee/PoppieFeeRouter.sol";
import {PoppieHubHook} from "../src/hooks/PoppieHubHook.sol";
import {PoppieEscrowHook} from "../src/hooks/PoppieEscrowHook.sol";
import {PoppieWrapperFactory} from "../src/wrapper/PoppieWrapperFactory.sol";
import {PoppieRouterGovernor} from "../src/governance/PoppieRouterGovernor.sol";
import {PoppieRiskSteward} from "../src/steward/PoppieRiskSteward.sol";
import {IPoppieRiskSteward} from "../src/interfaces/IPoppieRiskSteward.sol";
import {IPoppieEulerOracle} from "../src/interfaces/IPoppieEulerOracle.sol";
import {HUB_HOOKED_OPS, ESCROW_HOOKED_OPS} from "../src/hooks/HookOps.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_ALLOC, K_GUARD, K_RESERVE} from "../src/access/Roles.sol";

import {ScriptBase} from "./lib/ScriptBase.sol";
import {DeployConfig, HubParams, Deployment, AssetConfig, ListedAsset} from "./lib/Types.sol";
import {IEulerEarnMinimal} from "./lib/ExternalInterfaces.sol";

/// @title ConfigCheck
/// @notice Diffs on-chain state against the intended configuration (V2_PLAN section 7; CONTRACT_SPEC section 6
/// "Configuration"): every hub, the oracle, router, router governor, hooks, steward, wrapper factory, timelock and
/// Governor, and, per listed asset, the escrow vault settings the router governor does not check (caps, LTVs, flags,
/// IRM, fee receiver) plus oracle, routes and steward records. Run before and after each listing batch.
/// Fails on a zero hub fee receiver, on any role still held by the deployer, and if the hook and the fee router do
/// not point at each other. Read-only.
contract ConfigCheck is ScriptBase {
    address internal constant USD = address(840);

    string[] internal _diffs;

    /// @notice Revert listing every diff, or log "ConfigCheck: no diff".
    /// @param listedPath Stage-1 record (`batches/<name>/1-stage1.json`), or "" to check the deployment only.
    function run(
        string memory configPath,
        string memory deploymentPath,
        string memory assetsPath,
        string memory listedPath
    ) external {
        DeployConfig memory cfg = loadDeployConfig(configPath);
        Deployment memory d = loadDeployment(deploymentPath);
        string[] memory diffs = checkDeployment(cfg, d);
        if (bytes(listedPath).length != 0) {
            string[] memory more = checkAssets(d, loadAssets(assetsPath), loadListed(listedPath), false);
            diffs = _concat(diffs, more);
        }
        for (uint256 i; i < diffs.length; ++i) {
            console.log(diffs[i]);
        }
        require(diffs.length == 0, "ConfigCheck: diff found");
        console.log("ConfigCheck: no diff");
    }

    // -- Deployment -----------------------------------------------------------------------------

    function checkDeployment(DeployConfig memory cfg, Deployment memory d) public returns (string[] memory) {
        delete _diffs;
        _checkTimelockAndGovernor(cfg, d);
        _checkRoles(cfg, d);
        _checkWiring(cfg, d);
        for (uint256 i; i < d.hubs.length; ++i) {
            _checkHub(cfg.hubs[i], d, i);
        }
        for (uint256 i; i < d.earns.length; ++i) {
            IEulerEarnMinimal e = IEulerEarnMinimal(d.earns[i]);
            _eqA(string.concat("earn[", vm.toString(i), "].curator"), e.curator(), cfg.msOps);
            if (cfg.kAlloc != address(0)) {
                _true(string.concat("earn[", vm.toString(i), "] allocator K_ALLOC"), e.isAllocator(cfg.kAlloc));
            }
            _eqA(string.concat("earn[", vm.toString(i), "].pendingOwner"), e.pendingOwner(), d.timelock);
            _true(string.concat("earn[", vm.toString(i), "] has hubs in its supply queue"), e.supplyQueueLength() != 0);
        }
        return _diffs;
    }

    function _checkTimelockAndGovernor(DeployConfig memory cfg, Deployment memory d) internal {
        TimelockController tl = TimelockController(payable(d.timelock));
        _eqU("timelock.minDelay", tl.getMinDelay(), cfg.timelockDelay);
        _true("timelock: MS_ADMIN proposer", tl.hasRole(tl.PROPOSER_ROLE(), cfg.msAdmin));
        _true("timelock: MS_ADMIN executor", tl.hasRole(tl.EXECUTOR_ROLE(), cfg.msAdmin));
        _true("timelock: MS_OPS canceller", tl.hasRole(tl.CANCELLER_ROLE(), cfg.msOps));
        _false("timelock: deployer is admin", tl.hasRole(0x00, d.deployer));
        _false("timelock: deployer is proposer", tl.hasRole(tl.PROPOSER_ROLE(), d.deployer));

        IAccessControl g = IAccessControl(d.governor);
        bytes32 wildcard = bytes32(type(uint256).max);
        _true("governor: timelock admin", g.hasRole(0x00, d.timelock));
        _true("governor: timelock wildcard", g.hasRole(wildcard, d.timelock));
        _false("governor: deployer admin", g.hasRole(0x00, d.deployer));
        _false("governor: deployer wildcard", g.hasRole(wildcard, d.deployer));
        _true("governor: steward setLTV", g.hasRole(bytes32(IGovernance.setLTV.selector), d.steward));
        _true("governor: steward setCaps", g.hasRole(bytes32(IGovernance.setCaps.selector), d.steward));
    }

    function _poppie(Deployment memory d) internal pure returns (address[7] memory) {
        return [d.oracle, d.hubHook, d.feeRouter, d.escrowHook, d.wrapperFactory, d.routerGovernor, d.steward];
    }

    function _checkRoles(DeployConfig memory cfg, Deployment memory d) internal {
        address[7] memory c = _poppie(d);
        bytes32[9] memory roles =
            [bytes32(0x00), MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_ALLOC, K_GUARD, K_RESERVE];
        for (uint256 i; i < c.length; ++i) {
            _true(
                string.concat("timelock admin of ", vm.toString(c[i])), IAccessControl(c[i]).hasRole(0x00, d.timelock)
            );
            for (uint256 r; r < roles.length; ++r) {
                if (IAccessControl(c[i]).hasRole(roles[r], d.deployer)) {
                    _diff(string.concat("deployer still holds role ", vm.toString(roles[r]), " on ", vm.toString(c[i])));
                }
            }
        }
        _true("oracle MS_OPS", IAccessControl(d.oracle).hasRole(MS_OPS, cfg.msOps));
        _true("oracle K_PRICE", IAccessControl(d.oracle).hasRole(K_PRICE, cfg.kPrice));
        _true("oracle K_CONFIRM", IAccessControl(d.oracle).hasRole(K_CONFIRM, cfg.kConfirm));
        _true("hubHook MS_OPS", IAccessControl(d.hubHook).hasRole(MS_OPS, cfg.msOps));
        _true("hubHook K_GUARD", IAccessControl(d.hubHook).hasRole(K_GUARD, cfg.kGuard));
        _true("escrowHook MS_OPS", IAccessControl(d.escrowHook).hasRole(MS_OPS, cfg.msOps));
        _true("escrowHook K_GUARD", IAccessControl(d.escrowHook).hasRole(K_GUARD, cfg.kGuard));
        _true("feeRouter MS_OPS", IAccessControl(d.feeRouter).hasRole(MS_OPS, cfg.msOps));
        _true("routerGovernor MS_OPS", IAccessControl(d.routerGovernor).hasRole(MS_OPS, cfg.msOps));
        _true("steward MS_OPS", IAccessControl(d.steward).hasRole(MS_OPS, cfg.msOps));
        _true("steward K_TIGHTEN", IAccessControl(d.steward).hasRole(K_TIGHTEN, cfg.kTighten));
        _true("steward K_LOOSEN (phase 1: MS_OPS)", IAccessControl(d.steward).hasRole(K_LOOSEN, cfg.msOps));
    }

    function _checkWiring(DeployConfig memory cfg, Deployment memory d) internal {
        _eqA("hubHook.feeRouter", PoppieHubHook(d.hubHook).feeRouter(), d.feeRouter);
        _eqA("feeRouter.hook", PoppieFeeRouter(d.feeRouter).hook(), d.hubHook);
        _eqA("hubHook.evc", PoppieHubHook(d.hubHook).evc(), cfg.evc);
        _eqA("feeRouter.evc", PoppieFeeRouter(d.feeRouter).evc(), cfg.evc);
        _eqA("escrowHook.oracle", PoppieEscrowHook(d.escrowHook).oracle(), d.oracle);
        _eqA("escrowHook.wrapperFactory", PoppieEscrowHook(d.escrowHook).wrapperFactory(), d.wrapperFactory);
        _eqA("adapter.oracle", address(PoppieEulerAdapter(d.adapter).oracle()), d.oracle);
        _eqA(
            "wrapperFactory.dividendRecipient",
            PoppieWrapperFactory(d.wrapperFactory).dividendRecipient(),
            cfg.reserveSafe
        );
        _eqA("router.governor", EulerRouter(d.router).governor(), d.routerGovernor);
        _eqA("router USDC/USD", EulerRouter(d.router).getConfiguredOracle(cfg.usdc, USD), cfg.usdcUsdOracle);
        PoppieRouterGovernor rg = PoppieRouterGovernor(d.routerGovernor);
        _eqA("routerGovernor.router", rg.router(), d.router);
        _eqA("routerGovernor.adapter", rg.adapter(), d.adapter);
        _eqA("routerGovernor.wrapperFactory", rg.wrapperFactory(), d.wrapperFactory);
        _eqA("routerGovernor.vaultFactory", rg.vaultFactory(), cfg.eVaultFactory);
        _eqA("routerGovernor.poppieGovernor", rg.poppieGovernor(), d.governor);
        _eqA("routerGovernor.escrowHook", rg.escrowHook(), d.escrowHook);
        address[] memory sh = PoppieRiskSteward(d.steward).hubs();
        _eqU("steward hub count", sh.length, d.hubs.length);
    }

    function _checkHub(HubParams memory p, Deployment memory d, uint256 i) internal {
        IEVault h = IEVault(d.hubs[i]);
        string memory n = string.concat("hub[", vm.toString(i), "] ", p.name, ": ");
        _eqA(string.concat(n, "asset"), h.asset(), _usdc(d));
        _eqA(string.concat(n, "oracle"), h.oracle(), d.router);
        _eqA(string.concat(n, "unitOfAccount"), h.unitOfAccount(), USD);
        _eqA(string.concat(n, "governorAdmin"), h.governorAdmin(), d.governor);
        (address target, uint32 ops) = h.hookConfig();
        _eqA(string.concat(n, "hook target"), target, d.hubHook);
        _eqU(string.concat(n, "hooked ops"), ops, HUB_HOOKED_OPS);
        _true(string.concat(n, "CFG_DONT_SOCIALIZE_DEBT"), h.configFlags() & CFG_DONT_SOCIALIZE_DEBT != 0);
        _eqA(string.concat(n, "IRM"), h.interestRateModel(), d.irms[i]);
        _true(string.concat(n, "IRM set"), h.interestRateModel() != address(0));
        _eqU(string.concat(n, "interest fee"), h.interestFee(), p.interestFee);
        _eqU(string.concat(n, "max liquidation discount"), h.maxLiquidationDiscount(), p.maxLiquidationDiscount);
        if (h.feeReceiver() == address(0)) _diff(string.concat(n, "ZERO FEE RECEIVER"));
        _eqA(string.concat(n, "fee receiver"), h.feeReceiver(), p.feeReceiver);
        _true(string.concat(n, "registered in hub hook"), PoppieHubHook(d.hubHook).isHub(d.hubs[i]));
        _eqU(
            string.concat(n, "origination fee bps"), PoppieFeeRouter(d.feeRouter).feeBps(d.hubs[i]), p.originationFeeBps
        );
        _eqU(string.concat(n, "steward band"), uint8(PoppieRiskSteward(d.steward).hubBand(d.hubs[i])), p.band);
        (uint16 sc, uint16 bc) = PoppieRiskSteward(d.steward).capCeilings(d.hubs[i]);
        _eqU(string.concat(n, "supply cap ceiling"), sc, encodeCap(p.supplyCapCeiling));
        _eqU(string.concat(n, "borrow cap ceiling"), bc, encodeCap(p.borrowCapCeiling));
        (uint16 s, uint16 b) = h.caps();
        _true(string.concat(n, "supply cap <= ceiling, never raw 0"), s != 0 && resolveCap(s) <= resolveCap(sc));
        _true(string.concat(n, "borrow cap <= ceiling, never raw 0"), b != 0 && resolveCap(b) <= resolveCap(bc));
    }

    function _usdc(Deployment memory d) internal view returns (address) {
        return IEVault(d.hubs[0]).asset();
    }

    // -- Assets ---------------------------------------------------------------------------------

    /// @param atLaunch Also require the steward's launch LTVs (right after `list`).
    function checkAssets(Deployment memory d, AssetConfig[] memory assets, ListedAsset[] memory listed, bool atLaunch)
        public
        returns (string[] memory)
    {
        delete _diffs;
        for (uint256 i; i < assets.length; ++i) {
            _checkAsset(d, assets[i], listed[i], atLaunch);
        }
        return _diffs;
    }

    function _checkAsset(Deployment memory d, AssetConfig memory a, ListedAsset memory l, bool atLaunch) internal {
        string memory n = string.concat(a.symbol, ": ");
        IPoppieEulerOracle o = IPoppieEulerOracle(d.oracle);
        _true(string.concat(n, "oracle listed"), o.isListed(a.token));
        if (o.isListed(a.token)) {
            _eqU(string.concat(n, "oracle class"), uint8(o.getAssetData(a.token).priceClass), a.riskClass);
        }
        _true(string.concat(n, "approved token"), PoppieRouterGovernor(d.routerGovernor).isApprovedToken(a.token));
        EulerRouter r = EulerRouter(d.router);
        _eqA(string.concat(n, "route"), r.getConfiguredOracle(a.token, USD), d.adapter);
        address held = a.token;
        if (isWrapped(a.mechanism)) {
            _true(string.concat(n, "wrapped asset has a wrapper"), l.wrapper != address(0));
            _eqA(
                string.concat(n, "factory wrapperOf"),
                PoppieWrapperFactory(d.wrapperFactory).wrapperOf(a.token),
                l.wrapper
            );
            _eqA(string.concat(n, "router wrapper -> token"), r.resolvedVaults(l.wrapper), a.token);
            held = l.wrapper;
        } else {
            _eqA(string.concat(n, "multiplier asset has no wrapper"), l.wrapper, address(0));
        }
        _eqA(string.concat(n, "router escrow -> held"), r.resolvedVaults(l.escrow), held);
        _checkEscrow(d, a, l, held, n);
        _checkStewardAndLtvs(d, a, l, n, atLaunch);
    }

    function _checkEscrow(Deployment memory d, AssetConfig memory, ListedAsset memory l, address held, string memory n)
        internal
    {
        IEVault e = IEVault(l.escrow);
        _eqA(string.concat(n, "escrow asset"), e.asset(), held);
        _eqA(string.concat(n, "escrow oracle"), e.oracle(), address(0));
        _eqA(string.concat(n, "escrow unitOfAccount"), e.unitOfAccount(), address(0));
        _eqA(string.concat(n, "escrow governorAdmin"), e.governorAdmin(), d.governor);
        (address target, uint32 ops) = e.hookConfig();
        _eqA(string.concat(n, "escrow hook"), target, d.escrowHook);
        _eqU(string.concat(n, "escrow hooked ops"), ops, ESCROW_HOOKED_OPS);
        address factory = PoppieRouterGovernor(d.routerGovernor).vaultFactory();
        _false(string.concat(n, "escrow upgradeable"), GenericFactory(factory).getProxyConfig(l.escrow).upgradeable);
        _eqU(string.concat(n, "escrow config flags"), e.configFlags(), 0);
        _eqA(string.concat(n, "escrow IRM"), e.interestRateModel(), address(0));
        _eqA(string.concat(n, "escrow fee receiver"), e.feeReceiver(), address(0));
        _eqU(string.concat(n, "escrow has no collaterals"), e.LTVList().length, 0);
        (uint16 s, uint16 b) = e.caps();
        _eqU(string.concat(n, "escrow borrow cap raw 1"), b, 1);
        (uint16 ceil,) = PoppieRiskSteward(d.steward).capCeilings(l.escrow);
        _true(
            string.concat(n, "escrow supply cap <= ceiling, never raw 0"), s != 0 && resolveCap(s) <= resolveCap(ceil)
        );
    }

    function _checkStewardAndLtvs(
        Deployment memory d,
        AssetConfig memory a,
        ListedAsset memory l,
        string memory n,
        bool atLaunch
    ) internal {
        PoppieRiskSteward s = PoppieRiskSteward(d.steward);
        IPoppieRiskSteward.AssetInfo memory info = s.assetInfo(a.token);
        _true(string.concat(n, "steward listed"), info.listed);
        _eqA(string.concat(n, "steward escrow"), info.escrow, l.escrow);
        _eqA(string.concat(n, "steward wrapper"), info.wrapper, l.wrapper);
        (uint16 ceilB, uint16 ceilL) = s.classCeilings(info.riskClass);
        for (uint256 h; h < d.hubs.length; ++h) {
            (uint16 b, uint16 liq,,,) = IEVault(d.hubs[h]).LTVFull(l.escrow);
            bool inHub = info.riskClass == IPoppieRiskSteward.RiskClass.BlueChip || d.hubs[h] == info.bandHub;
            string memory hn = string.concat(n, "hub[", vm.toString(h), "] ");
            if (!inHub) {
                _eqU(string.concat(hn, "borrow LTV outside band hub"), b, 0);
                continue;
            }
            _true(string.concat(hn, "borrow <= liquidation"), b <= liq);
            _true(string.concat(hn, "borrow <= class ceiling"), b <= ceilB);
            _true(string.concat(hn, "liquidation <= class ceiling"), liq <= ceilL);
            if (atLaunch) {
                _eqU(string.concat(hn, "launch borrow LTV"), b, ceilB / 2);
                _eqU(string.concat(hn, "launch liquidation LTV"), liq, ceilL / 2);
            }
        }
    }

    // -- Diff helpers ---------------------------------------------------------------------------

    function _diff(string memory s) internal {
        _diffs.push(s);
    }

    function _true(string memory what, bool ok) internal {
        if (!ok) _diff(string.concat("expected true: ", what));
    }

    function _false(string memory what, bool v) internal {
        if (v) _diff(string.concat("expected false: ", what));
    }

    function _eqA(string memory what, address got, address want) internal {
        if (got != want) _diff(string.concat(what, ": got ", vm.toString(got), " want ", vm.toString(want)));
    }

    function _eqU(string memory what, uint256 got, uint256 want) internal {
        if (got != want) _diff(string.concat(what, ": got ", vm.toString(got), " want ", vm.toString(want)));
    }

    function _concat(string[] memory a, string[] memory b) internal pure returns (string[] memory c) {
        c = new string[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            c[a.length + i] = b[i];
        }
    }
}
