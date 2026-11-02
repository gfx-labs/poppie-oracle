// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {AssetConfig, Mechanism, ListedAsset} from "../../script/lib/Types.sol";
import {IPoppieBalanceWrapper} from "../../src/interfaces/IPoppieBalanceWrapper.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {ForkBase, Arbitrum} from "./ForkBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebasingToken} from "../mocks/MockRebasingToken.sol";
import {MockFreezableToken} from "../mocks/MockFreezableToken.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function enableModule(address module) external;
    function isModuleEnabled(address module) external view returns (bool);
}

interface IModuleProxyFactory {
    function deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @notice Zodiac Roles v2, the subset used (ABI from the verified mastercopy on Arbitrum). The enum values below are
/// Roles v2's: ParameterType {None, Static, Dynamic, Tuple, Array, Calldata, AbiEncoded}; Operator Pass=0, Or=2,
/// Matches=5, EqualTo=16, WithinAllowance=28 (logical nodes such as Or take ParameterType None); ExecutionOptions
/// None=0. The tests check behaviour both ways, so a
/// wrong value fails them.
interface IRoles {
    struct ConditionFlat {
        uint8 parent;
        uint8 paramType;
        uint8 operator;
        bytes compValue;
    }

    function setUp(bytes memory initParams) external;
    function assignRoles(address module, bytes32[] memory roleKeys, bool[] memory memberOf) external;
    function scopeTarget(bytes32 roleKey, address targetAddress) external;
    function allowFunction(bytes32 roleKey, address targetAddress, bytes4 selector, uint8 options) external;
    function scopeFunction(
        bytes32 roleKey,
        address targetAddress,
        bytes4 selector,
        ConditionFlat[] memory conditions,
        uint8 options
    ) external;
    function setAllowance(
        bytes32 key,
        uint128 balance,
        uint128 maxRefill,
        uint128 refill,
        uint64 period,
        uint64 timestamp
    ) external;
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);
}

/// @notice POP-16: the launch rehearsed on an Arbitrum fork with the real scripts (not the harness): `Deploy`,
/// listing batches (multiplier, balance-changing and distributing tokens; the latter two through the wrapper path),
/// `ConfigCheck` before and after; a split and a dividend rebase end to end; issuer freeze (on-chain symptom only,
/// Q11); the reserve Safe's Roles-module scope for K_RESERVE; Earn accepting the deployed hubs; the dividend sweep.
///
/// Token availability: no xStocks / Reality / Dinari / Ondo addresses are configured in this repo, so every issuer
/// token here is a mock with the issuer's mechanism (fallbacks reported on POP-16). To rehearse with a real token,
/// list it the same way and fund holders with `deal`.
contract LaunchRehearsalForkTest is ForkBase {
    bytes32 internal constant K_RESERVE_ROLE = keccak256("K_RESERVE");

    MockERC20 internal mul;
    MockRebasingToken internal reb;
    MockERC20 internal div; // distributing: the dividend arrives as USDC on the wrapper
    MockFreezableToken internal frz;
    MockFreezableToken internal frzW; // freezable, wrapped
    ListedAsset[] internal listed;
    AssetConfig[] internal assetList;

    address internal borrower = makeAddr("borrower");

    function setUp() public {
        if (!_forkAndDeploy()) {
            vm.skip(true);
            return;
        }
        _assertNoDiff(checkScript.checkDeployment(_cfg(), d)); // before

        mul = new MockERC20("Ondo-like", "oSTK", 18);
        reb = new MockRebasingToken("xStock-like", "xSTK", 18);
        div = new MockERC20("Dinari-like", "dSTK", 18);
        frz = new MockFreezableToken("Freezable", "fzSTK", 18);
        frzW = new MockFreezableToken("Freezable wrapped", "fzwSTK", 18);

        AssetConfig[] memory a = new AssetConfig[](5);
        a[0] = AssetConfig("oSTK", address(mul), Mechanism.Multiplier, 0, 0, 1e18, 1_000_000e18);
        a[1] = AssetConfig("xSTK", address(reb), Mechanism.BalanceChanging, 0, 0, 1e18, 1_000_000e18);
        a[2] = AssetConfig("dSTK", address(div), Mechanism.Distributing, 1, 1, 1e18, 1_000_000e18);
        a[3] = AssetConfig("fzSTK", address(frz), Mechanism.Multiplier, 2, 2, 1e18, 1_000_000e18);
        a[4] = AssetConfig("fzwSTK", address(frzW), Mechanism.BalanceChanging, 3, 3, 1e18, 1_000_000e18);
        mul.mint(deployer, 1e18);
        reb.mint(deployer, 2e18);
        div.mint(deployer, 2e18);
        frz.mint(deployer, 1e18);
        frzW.mint(deployer, 2e18);

        ListedAsset[] memory l = _listViaScripts(a);
        for (uint256 i; i < a.length; ++i) {
            listed.push(l[i]);
            assetList.push(a[i]);
        }
        address[] memory t = new address[](5);
        for (uint256 i; i < 5; ++i) {
            t[i] = a[i].token;
        }
        _goLive(t, 100e18);
    }

    function _assets() internal view returns (AssetConfig[] memory a, ListedAsset[] memory l) {
        a = assetList;
        l = listed;
    }

    function _deposit(uint256 idx, address who, uint256 amount, IEVault hub) internal {
        ListedAsset memory l = listed[idx];
        MockERC20(l.token).mint(who, amount);
        vm.startPrank(who);
        address held = l.token;
        uint256 toEscrow = amount;
        if (l.wrapper != address(0)) {
            IERC20(l.token).approve(l.wrapper, amount);
            toEscrow = IERC4626(l.wrapper).deposit(IERC20(l.token).balanceOf(who), who);
            held = l.wrapper;
        }
        IERC20(held).approve(l.escrow, toEscrow);
        IEVault(l.escrow).deposit(toEscrow, who);
        IEVC(Arbitrum.EVC).enableCollateral(who, l.escrow);
        if (address(hub) != address(0)) IEVC(Arbitrum.EVC).enableController(who, address(hub));
        vm.stopPrank();
    }

    function _value(uint256 idx, address who) internal view returns (uint256) {
        IEVault e = IEVault(listed[idx].escrow);
        address router = IEVault(d.hubs[0]).oracle();
        (bool ok, bytes memory ret) = router.staticcall(
            abi.encodeWithSignature("getQuote(uint256,address,address)", e.balanceOf(who), address(e), USD)
        );
        require(ok, "quote");
        return abi.decode(ret, (uint256));
    }

    // -- Deploy + listing + ConfigCheck ---------------------------------------------------------

    function test_configCheckAfterListing() public {
        (AssetConfig[] memory a, ListedAsset[] memory l) = _assets();
        _assertNoDiff(checkScript.checkAssets(d, a, l, true));
        _assertNoDiff(checkScript.checkDeployment(_cfg(), d));
        // Wrapper path for balance-changing and distributing.
        assertEq(l[0].wrapper, address(0));
        assertTrue(l[1].wrapper != address(0));
        assertTrue(l[2].wrapper != address(0));
    }

    function test_earnAcceptsDeployedHubs() public view {
        (bool ok, bytes memory ret) =
            Arbitrum.EULER_EARN_FACTORY.staticcall(abi.encodeWithSignature("isStrategyAllowed(address)", d.hubs[3]));
        assertTrue(ok && abi.decode(ret, (bool)));
        assertEq(d.earns.length, 2);
    }

    // -- Split and dividend rebase end to end ---------------------------------------------------

    function test_splitAndDividendRebaseThroughStack() public {
        IEVault prime = IEVault(d.hubs[0]);
        _deposit(1, borrower, 10e18, prime);
        uint256 v0 = _value(1, borrower);
        assertApproxEqRel(v0, 1_000e18, 1e15);
        _borrow(prime, borrower, 300e6);

        // 2-for-1 split with the price pushed at the split: value unchanged once confirmed.
        reb.rebase(2e18);
        _goLive(address(reb), 50e18);
        assertApproxEqRel(_value(1, borrower), v0, 1e15);

        // 1% in-kind dividend: value up 1%.
        reb.rebaseBy(101, 100);
        assertApproxEqRel(_value(1, borrower), v0 * 101 / 100, 1e15);

        // Still borrowable and repayable end to end.
        _borrow(prime, borrower, 10e6);
        deal(Arbitrum.USDC, borrower, 1_000e6);
        vm.startPrank(borrower);
        IERC20(Arbitrum.USDC).approve(address(prime), type(uint256).max);
        prime.repay(type(uint256).max, borrower);
        vm.stopPrank();
        assertEq(prime.debtOf(borrower), 0);
    }

    // -- Issuer freeze (Q11: assert the symptom only) -------------------------------------------

    function test_issuerFreezeOfEscrowBlocksWithdrawals() public {
        _deposit(3, borrower, 10e18, IEVault(address(0)));
        frz.freeze(listed[3].escrow, true);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(MockFreezableToken.AccountFrozen.selector, listed[3].escrow));
        IEVault(listed[3].escrow).withdraw(1e18, borrower, borrower);
    }

    function test_issuerFreezeOfWrapperBlocksUnwrap() public {
        _deposit(4, borrower, 10e18, IEVault(address(0)));
        frzW.freeze(listed[4].wrapper, true);
        // Escrow -> wrapper shares still move (the wrapper share is not frozen)...
        vm.startPrank(borrower);
        IEVault(listed[4].escrow).redeem(IEVault(listed[4].escrow).balanceOf(borrower), borrower, borrower);
        uint256 shares = IERC20(listed[4].wrapper).balanceOf(borrower);
        // ...but unwrapping to the token fails.
        vm.expectRevert(abi.encodeWithSelector(MockFreezableToken.AccountFrozen.selector, listed[4].wrapper));
        IERC4626(listed[4].wrapper).redeem(shares, borrower, borrower);
        vm.stopPrank();
    }

    // -- Dividend sweep -------------------------------------------------------------------------

    function test_dividendSweepToReserveNeverUnderlying() public {
        _deposit(2, borrower, 10e18, IEVault(address(0)));
        address w = listed[2].wrapper;
        uint256 underlying = IERC20(address(div)).balanceOf(w);
        deal(Arbitrum.USDC, w, 123e6); // a stablecoin dividend reaching the wrapper
        uint256 before = IERC20(Arbitrum.USDC).balanceOf(cfg.reserveSafe);
        IPoppieBalanceWrapper(w).sweep(Arbitrum.USDC);
        assertEq(IERC20(Arbitrum.USDC).balanceOf(cfg.reserveSafe) - before, 123e6);
        assertEq(IERC20(address(div)).balanceOf(w), underlying);
        vm.expectRevert(IPoppieBalanceWrapper.CannotSweepUnderlying.selector);
        IPoppieBalanceWrapper(w).sweep(address(div));
    }

    // -- Reserve Safe + Roles module ------------------------------------------------------------

    function _reserveWithRoles(address kReserve, uint128 allowance) internal returns (address safe, IRoles roles) {
        address owner = makeAddr("reserveOwner");
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory init =
            abi.encodeCall(ISafe.setup, (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))));
        safe = ISafeProxyFactory(Arbitrum.SAFE_PROXY_FACTORY).createProxyWithNonce(Arbitrum.SAFE_SINGLETON_L2, init, 1);

        // Roles modifier: owner = the Safe's owner here (MS_OPS in production), avatar = target = the reserve Safe.
        roles = IRoles(
            IModuleProxyFactory(Arbitrum.MODULE_PROXY_FACTORY)
                .deployModule(
                    Arbitrum.ROLES_V2_MASTERCOPY,
                    abi.encodeCall(IRoles.setUp, (abi.encode(owner, safe, safe))),
                    uint256(keccak256("poppie-reserve"))
                )
        );
        vm.prank(safe);
        ISafe(safe).enableModule(address(roles));

        vm.startPrank(owner);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = K_RESERVE_ROLE;
        bool[] memory member = new bool[](1);
        member[0] = true;
        roles.assignRoles(kReserve, keys, member);

        // USDC.approve(spender in hubs, amount within allowance).
        roles.scopeTarget(K_RESERVE_ROLE, Arbitrum.USDC);
        IRoles.ConditionFlat[] memory c = new IRoles.ConditionFlat[](3 + d.hubs.length);
        c[0] = IRoles.ConditionFlat(0, 5, 5, ""); // root: Calldata, Matches
        c[1] = IRoles.ConditionFlat(0, 0, 2, ""); // spender: Or (logical nodes are ParameterType.None)
        c[2] = IRoles.ConditionFlat(0, 1, 28, abi.encode(K_RESERVE_ROLE)); // amount: Static, WithinAllowance
        for (uint256 i; i < d.hubs.length; ++i) {
            c[3 + i] = IRoles.ConditionFlat(1, 1, 16, abi.encode(d.hubs[i])); // EqualTo hub
        }
        roles.scopeFunction(K_RESERVE_ROLE, Arbitrum.USDC, IERC20.approve.selector, c, 0);
        roles.setAllowance(K_RESERVE_ROLE, allowance, allowance, 0, 0, 0);

        // hub.repay(amount, receiver) on the hubs.
        for (uint256 i; i < d.hubs.length; ++i) {
            roles.scopeTarget(K_RESERVE_ROLE, d.hubs[i]);
            roles.allowFunction(K_RESERVE_ROLE, d.hubs[i], IBorrowing.repay.selector, 0);
        }
        vm.stopPrank();
    }

    function test_reserveRolesScopeAndBadDebtRepay() public {
        address kReserve = makeAddr("kReserve");
        (address safe, IRoles roles) = _reserveWithRoles(kReserve, 1_000e6);
        deal(Arbitrum.USDC, safe, 10_000e6);
        IEVault prime = IEVault(d.hubs[0]);

        // Bad debt: borrow, gap down 75%, liquidate everything; CFG_DONT_SOCIALIZE_DEBT leaves the rest.
        _deposit(0, borrower, 10e18, prime);
        _borrow(prime, borrower, 340e6);
        _push(address(mul), 25e18);
        vm.prank(cfg.kConfirm);
        (bool okc,) = d.oracle.call(abi.encodeWithSignature("confirm(address,uint128)", address(mul), uint128(25e18)));
        assertTrue(okc);
        _liquidate(prime, borrower, listed[0].escrow);
        uint256 bad = prime.debtOf(borrower);
        assertGt(bad, 0);

        vm.startPrank(kReserve);
        // Allowed: approve a hub within the allowance, then repay.
        roles.execTransactionWithRole(
            Arbitrum.USDC, 0, abi.encodeCall(IERC20.approve, (address(prime), bad)), 0, K_RESERVE_ROLE, true
        );
        roles.execTransactionWithRole(
            address(prime), 0, abi.encodeCall(IBorrowing.repay, (bad, borrower)), 0, K_RESERVE_ROLE, true
        );
        assertEq(prime.debtOf(borrower), 0);

        // Denied: approve a non-hub, approve above the remaining allowance, transfer, any other hub function.
        vm.expectRevert();
        roles.execTransactionWithRole(
            Arbitrum.USDC, 0, abi.encodeCall(IERC20.approve, (kReserve, 1e6)), 0, K_RESERVE_ROLE, true
        );
        vm.expectRevert();
        roles.execTransactionWithRole(
            Arbitrum.USDC, 0, abi.encodeCall(IERC20.approve, (address(prime), 1_000e6)), 0, K_RESERVE_ROLE, true
        );
        vm.expectRevert();
        roles.execTransactionWithRole(
            Arbitrum.USDC, 0, abi.encodeCall(IERC20.transfer, (kReserve, 1e6)), 0, K_RESERVE_ROLE, true
        );
        vm.expectRevert();
        roles.execTransactionWithRole(
            address(prime), 0, abi.encodeCall(IERC4626.deposit, (1e6, kReserve)), 0, K_RESERVE_ROLE, true
        );
        vm.expectRevert();
        roles.execTransactionWithRole(
            d.steward, 0, abi.encodeWithSignature("promote(address)", address(mul)), 0, K_RESERVE_ROLE, true
        );
        vm.stopPrank();

        // A non-member cannot use the role at all.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        roles.execTransactionWithRole(
            Arbitrum.USDC, 0, abi.encodeCall(IERC20.approve, (address(prime), 1e6)), 0, K_RESERVE_ROLE, true
        );
    }

    // Silence unused import.
    function _unused() internal pure returns (bytes4) {
        return IPoppieRiskSteward.promote.selector;
    }
}
