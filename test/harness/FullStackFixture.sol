// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVault, IGovernance, IBorrowing, IRiskManager, ILiquidation} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {CFG_DONT_SOCIALIZE_DEBT} from "evk/EVault/shared/Constants.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";

import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/oracle/PoppieEulerAdapter.sol";
import {PoppieFeeRouter} from "../../src/fee/PoppieFeeRouter.sol";
import {PoppieHubHook} from "../../src/hooks/PoppieHubHook.sol";
import {PoppieEscrowHook} from "../../src/hooks/PoppieEscrowHook.sol";
import {PoppieRouterGovernor} from "../../src/governance/PoppieRouterGovernor.sol";
import {PoppieRiskSteward} from "../../src/steward/PoppieRiskSteward.sol";
import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";
import {HUB_HOOKED_OPS, ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_GUARD} from "../../src/access/Roles.sol";

import {WrapperFixture} from "./WrapperFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceAdapter} from "../mocks/MockPriceAdapter.sol";

/// @notice The whole Poppie stack on the local EVK, every contract real (no mocks of Poppie code): oracle,
/// adapter, fee router, hub hook, escrow hook, wrapper factory and wrappers, router governor (governing the
/// EulerRouter), risk steward (holding the setLTV / setCaps selector roles on the Euler Governor). Four hubs
/// (Prime, M1, M2, M3) configured as the deploy script would. Assets are listed through the real two-stage
/// listing flow (`_listAsset`): stage 1 as the deployer key, stage 2 as the MS_OPS Safe. No fork.
///
/// Phase-1 role holders: `ops` is the MS_OPS Safe and also holds K_LOOSEN; `timelock` holds DEFAULT_ADMIN_ROLE on
/// every Poppie contract.
abstract contract FullStackFixture is WrapperFixture {
    uint256 internal constant T0 = 1_000_000;
    uint16 internal constant FEE_BPS = 25;

    address internal ops = makeAddr("ops");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");
    address internal guard = makeAddr("guard");
    address internal tightener = makeAddr("tightener");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal lender = makeAddr("lender");
    address internal liquidator = makeAddr("liquidator");

    PoppieEulerOracle internal oracle;
    PoppieEulerAdapter internal adapter;
    PoppieHubHook internal hubHook;
    PoppieFeeRouter internal feeRouter;
    PoppieEscrowHook internal escrowHook;
    PoppieRouterGovernor internal routerGovernor;
    PoppieRiskSteward internal steward;
    /// @dev Stands in for the off-the-shelf USDC/USD fixed-rate oracle (euler-price-oracle's FixedRateOracle needs a
    /// solady remapping this repo does not configure).
    MockPriceAdapter internal usdcOracle;

    IEVault internal prime;
    IEVault internal hubM1;
    IEVault internal hubM2;
    IEVault internal hubM3;

    mapping(address token => IEVault) internal escrowOf;
    mapping(address token => address) internal heldBy; // token or its wrapper
    address[] internal listedTokens;

    /// @dev 1e9 whole tokens (18 decimals): far above anything a test deposits.
    uint256 internal constant ESCROW_CEILING_AMOUNT = 1e27;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);

        oracle = new PoppieEulerOracle(timelock);
        adapter = new PoppieEulerAdapter(IPoppieEulerOracle(address(oracle)));

        // Hook <-> router: both immutable; the hook gets the router's CREATE address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        hubHook = new PoppieHubHook(timelock, address(evc), predicted);
        feeRouter = new PoppieFeeRouter(timelock, address(evc), address(hubHook));
        assertEq(address(feeRouter), predicted, "hook/router wiring");

        escrowHook = new PoppieEscrowHook(timelock, address(evc), address(oracle), address(wrapperFactory));
        routerGovernor = new PoppieRouterGovernor(
            timelock,
            address(router),
            address(adapter),
            address(wrapperFactory),
            address(factory),
            address(governor),
            address(escrowHook)
        );
        steward = new PoppieRiskSteward(timelock, address(governor));

        // USDC/USD fixed rate, then hand the router to the router governor (later route changes are timelocked).
        usdcOracle = new MockPriceAdapter();
        usdcOracle.setPrice(address(usdc), 1e18);
        router.govSetConfig(address(usdc), USD, address(usdcOracle));
        router.transferGovernance(address(routerGovernor));

        vm.startPrank(admin);
        governor.grantRole(bytes32(IGovernance.setLTV.selector), address(steward));
        governor.grantRole(bytes32(IGovernance.setCaps.selector), address(steward));
        vm.stopPrank();

        vm.startPrank(timelock);
        oracle.grantRole(MS_OPS, ops);
        oracle.grantRole(K_PRICE, keeper);
        oracle.grantRole(K_CONFIRM, confirmer);
        hubHook.grantRole(MS_OPS, ops);
        hubHook.grantRole(K_GUARD, guard);
        feeRouter.grantRole(MS_OPS, ops);
        escrowHook.grantRole(MS_OPS, ops);
        escrowHook.grantRole(K_GUARD, guard);
        routerGovernor.grantRole(MS_OPS, ops);
        steward.grantRole(MS_OPS, ops);
        steward.grantRole(K_LOOSEN, ops); // phase 1
        steward.grantRole(K_TIGHTEN, tightener);
        vm.stopPrank();

        prime = _newHub(IPoppieRiskSteward.RiskClass.BlueChip, 0.08e4);
        hubM1 = _newHub(IPoppieRiskSteward.RiskClass.M1, 0.1e4);
        hubM2 = _newHub(IPoppieRiskSteward.RiskClass.M2, 0.15e4);
        hubM3 = _newHub(IPoppieRiskSteward.RiskClass.M3, 0.2e4);

        // Liquidator: USDC to repay seized debt in the same batch.
        usdc.mint(liquidator, 10_000_000e6);
        vm.prank(liquidator);
        usdc.approve(address(prime), type(uint256).max);
    }

    // -- Deployment helpers (what Deploy.s.sol does per hub) ------------------------------------

    function _newHub(IPoppieRiskSteward.RiskClass band, uint16 maxDiscount) internal returns (IEVault h) {
        h = _createHub();
        h.setMaxLiquidationDiscount(maxDiscount);
        h.setFeeReceiver(feeReceiver);
        h.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT);
        h.setCaps(steward_encode(500_000_000e6), steward_encode(250_000_000e6));
        h.setHookConfig(address(hubHook), HUB_HOOKED_OPS);
        h.setGovernorAdmin(address(governor));

        vm.startPrank(timelock);
        hubHook.registerHub(address(h));
        steward.addHub(address(h), band);
        vm.stopPrank();

        vm.startPrank(ops);
        feeRouter.setFeeBps(address(h), FEE_BPS);
        IPoppieRiskSteward.CapCeilingChange[] memory c = new IPoppieRiskSteward.CapCeilingChange[](1);
        c[0] = IPoppieRiskSteward.CapCeilingChange(address(h), steward_encode(1e15), steward_encode(5e14));
        steward.setCapCeiling(c);
        vm.stopPrank();

        // Lender liquidity.
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(h), type(uint256).max);
        h.deposit(1_000_000e6, lender);
        vm.stopPrank();
    }

    /// @dev Same encoder as the steward (largest AmountCap <= amount, never raw 0).
    function steward_encode(uint256 amount) internal pure returns (uint16) {
        if (amount == 0) return 1;
        uint256 m = amount * 100;
        uint256 e;
        while (m > 1023) {
            m /= 10;
            ++e;
        }
        return uint16((m << 6) | e);
    }

    // -- Listing flow ---------------------------------------------------------------------------

    /// @notice List `token` end to end and take it Live at `price` (18-decimal USD per whole token).
    /// Stage 1 (deployer key): wrapper if `wrapped`, escrow, seed deposit, hook config, governance hand-off.
    /// Stage 2 (MS_OPS): oracle listing, addWrapper, addRoute, addResolvedVault, cap ceiling, steward.list.
    /// The approved-token flag is a timelock action done ahead of the batch.
    function _listAsset(address token, bool wrapped, IPoppieRiskSteward.RiskClass riskClass, IEVault hub, uint128 price)
        internal
        returns (IEVault escrow)
    {
        uint256 seed = 10 ** MockERC20(token).decimals();
        vm.prank(timelock);
        routerGovernor.setApprovedToken(token, true);

        // Stage 1.
        address held = token;
        if (wrapped) held = address(_createWrapper(token, seed));
        escrow = _createEscrow(held);
        _mintHeld(token, held, address(this), seed);
        IERC20(held).approve(address(escrow), type(uint256).max);
        escrow.deposit(IERC20(held).balanceOf(address(this)), deployer);
        escrow.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
        escrow.setGovernorAdmin(address(governor));

        // Stage 2.
        vm.startPrank(ops);
        address[] memory t = new address[](1);
        t[0] = token;
        IPoppieEulerOracle.PriceClass[] memory pc = new IPoppieEulerOracle.PriceClass[](1);
        pc[0] = IPoppieEulerOracle.PriceClass(uint8(riskClass));
        oracle.listAssets(t, pc);
        if (wrapped) routerGovernor.addWrapper(held);
        routerGovernor.addRoute(token);
        routerGovernor.addResolvedVault(address(escrow));
        IPoppieRiskSteward.CapCeilingChange[] memory cc = new IPoppieRiskSteward.CapCeilingChange[](1);
        cc[0] = IPoppieRiskSteward.CapCeilingChange(address(escrow), steward_encode(ESCROW_CEILING_AMOUNT), 1);
        steward.setCapCeiling(cc);
        IPoppieRiskSteward.Listing[] memory l = new IPoppieRiskSteward.Listing[](1);
        l[0] = IPoppieRiskSteward.Listing(token, address(escrow), address(hub), riskClass);
        steward.list(l);
        vm.stopPrank();

        escrowOf[token] = escrow;
        heldBy[token] = held;
        listedTokens.push(token);
        _goLive(token, price);
    }

    /// @dev Mint `token` to `to` and, for a wrapped asset, wrap it: `to` ends up holding `held`.
    function _mintHeld(address token, address held, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount);
        if (held == token) return;
        vm.startPrank(to);
        IERC20(token).approve(held, amount);
        PoppieBalanceWrapper(held).deposit(IERC20(token).balanceOf(to), to);
        vm.stopPrank();
    }

    // -- Oracle helpers -------------------------------------------------------------------------

    function _push(address token, uint128 price) internal {
        address[] memory a = new address[](1);
        a[0] = token;
        uint128[] memory p = new uint128[](1);
        p[0] = price;
        vm.prank(keeper);
        oracle.keeperPushPrices(a, p);
    }

    function _confirm(address token, uint128 price) internal {
        vm.prank(confirmer);
        oracle.confirm(token, price);
    }

    function _goLive(address token, uint128 price) internal {
        _push(token, price);
        if (oracle.state(token) != IPoppieEulerOracle.PriceState.Live) _confirm(token, price);
    }

    /// @dev Re-push every listed token's last price (keeps them Live across warps).
    function _refresh() internal {
        for (uint256 i; i < listedTokens.length; ++i) {
            address t = listedTokens[i];
            _push(t, oracle.getAssetData(t).lastPrice);
        }
    }

    function _warpAndRefresh(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        _refresh();
    }

    function _state(address token) internal view returns (IPoppieEulerOracle.PriceState) {
        return oracle.state(token);
    }

    // -- Account helpers ------------------------------------------------------------------------

    /// @dev Give `who` `amount` of `token` as collateral in its escrow (wrapping first if needed), and enable the
    /// escrow as collateral and `hub` as controller.
    function _depositCollateral(address token, address who, uint256 amount, IEVault hub) internal {
        IEVault escrow = escrowOf[token];
        address held = heldBy[token];
        _mintHeld(token, held, who, amount);
        vm.startPrank(who);
        IERC20(held).approve(address(escrow), type(uint256).max);
        escrow.deposit(IERC20(held).balanceOf(who), who);
        evc.enableCollateral(who, address(escrow));
        if (address(hub) != address(0)) evc.enableController(who, address(hub));
        vm.stopPrank();
    }

    function _borrowItem(IEVault h, address account, uint256 amount, address receiver)
        internal
        pure
        returns (IEVC.BatchItem memory)
    {
        return IEVC.BatchItem({
            targetContract: address(h),
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(IBorrowing.borrow, (amount, receiver))
        });
    }

    function _forwardItem(IEVault h, address account, address to) internal view returns (IEVC.BatchItem memory) {
        return IEVC.BatchItem({
            targetContract: address(feeRouter),
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(PoppieFeeRouter.forward, (address(h), to))
        });
    }

    /// @dev The integrator batch: borrow to the fee router, forward the net to `account`.
    function _borrow(IEVault h, address account, uint256 amount) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(h, account, amount, address(feeRouter));
        items[1] = _forwardItem(h, account, account);
        vm.prank(account);
        evc.batch(items);
    }

    /// @dev Liquidator batch: liquidate `violator`'s `collateral` position on `h` (max), then repay all the debt it
    /// took over, so its own account check passes without collateral of its own. Then release the controller.
    function _liquidate(IEVault h, address violator, IEVault collateral) internal {
        vm.startPrank(liquidator);
        usdc.approve(address(h), type(uint256).max);
        evc.enableController(liquidator, address(h));
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: address(h),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(ILiquidation.liquidate, (violator, address(collateral), type(uint256).max, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(h),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(IBorrowing.repay, (type(uint256).max, liquidator))
        });
        items[2] = IEVC.BatchItem({
            targetContract: address(h),
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(IRiskManager.disableController, ())
        });
        evc.batch(items);
        vm.stopPrank();
    }

    function _debt(IEVault h, address account) internal view returns (uint256) {
        return h.debtOf(account);
    }

    function _hubs() internal view returns (IEVault[4] memory) {
        return [prime, hubM1, hubM2, hubM3];
    }
}
