// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Fork tests against real Robinhood Stock Tokens (AAPL, SOXX) on Robinhood
// Chain (chain 4663, Arbitrum Nitro). Local fork only: nothing is broadcast.
// Skipped unless ROBINHOOD_RPC_URL is set, e.g.
//   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/Robinhood*'
//
// Addresses and roles were read on-chain on 2026-11-04 (block ~106.0M); see
// docs/EVAL_FINDINGS.md (RH-*). Robinhood has said the tokens may come to
// Arbitrum One; these tests check the token design, not that deployment.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {PoppieEulerOracle} from "../../src/PoppieEulerOracle.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";

interface IRhStockToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function supportsInterface(bytes4) external view returns (bool);
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
    function balanceOfUI(address) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
    function oraclePaused() external view returns (bool);
    function tokenPaused() external view returns (bool);
    function paused() external view returns (bool);
    function uid() external view returns (bytes32);
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address);
    function updateMultiplier(uint256) external;
    function updateMultiplier(uint256, uint256) external;
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function adminBurn(address, uint256) external;
    function pause() external;
    function unpause() external;
    function pauseOracle() external;
    function unpauseOracle() external;
}

interface IRhRegistry {
    function implementation() external view returns (address);
    function hasRole(bytes32, address) external view returns (bool);
    function paused() external view returns (bool);
    function pause() external;
    function blockAccounts(address[] calldata) external;
    function isBlocked(address) external view returns (bool);
}

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract RhEscrow4626 is ERC4626 {
    constructor(IERC20 a) ERC20("escrow", "e") ERC4626(a) {}
}

contract RobinhoodChainForkTest is Test {
    IRhStockToken internal constant AAPL = IRhStockToken(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9);
    IRhStockToken internal constant SOXX = IRhStockToken(0x75742c18BC1f1C5c5f448f4C9D9C6F66dafAAa38);
    IAggregatorV3 internal constant AAPL_FEED = IAggregatorV3(0x6B22A786bAa607d76728168703a39Ea9C99f2cD0);

    // One contract for all tokens: beacon (implementation), roles, blocklist, global pause.
    IRhRegistry internal constant REGISTRY = IRhRegistry(0xe10b6f6B275de231345c20D14Ab812db62151b00);
    address internal constant IMPL = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;

    // Role holders (RoleGranted logs on the registry). All are EOAs except LIQUIDATOR_CONTRACT.
    address internal constant DEFAULT_ADMIN = 0xD6f8378F8e440c65F8382F5f2728c78DfD55B66d;
    address internal constant BEACON_UPGRADER = 0xCd8C6182e7C6Ca3B5156D6a90a67719d7e2Be094;
    address internal constant MINTER = 0x2b94105fFf37630f98e1f24811daD588FC5C3A87;
    address internal constant BURNER = 0x6E40B50A40C1db42A85a0E8fe8FF7d9CbFc2D8C1;
    address internal constant ADMIN_BURNER = 0x957B6de6525C63349f7619743Ef1E0ad93cd74D4;
    address internal constant PAUSER = 0xe7BCB188254Bc6eBBfF63014DfED4cD4A024F22A;
    address internal constant TOKEN_PAUSER = 0xFCcF56B674113d9C4eb0F9B3370930ceD9E6Ab23;
    address internal constant ORACLE_PAUSER = 0x7369d100c00F28E45D779ac9d4b1c7afa61e4aBC;
    address internal constant MULTIPLIER_UPDATER = 0x92905e8d0e2301BA143215B8D86D63fFD4188143;
    address internal constant BLOCKER = 0x913cA87347391218e5De2C17c5A0AEba8B0b28fD;
    address internal constant LIQUIDATOR_CONTRACT = 0x13643b89b19245201b29d556EDDe5CF18f749C08; // MINTER + BURNER

    address internal constant USD = address(840);
    uint256 internal constant WAD = 1e18;

    address internal user = address(0xA11CE);
    address internal liquidator = address(0x11D);
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        vm.prank(MINTER);
        AAPL.mint(user, 100e18);
    }

    modifier onlyFork() {
        if (!live) vm.skip(true);
        _;
    }

    function _escrowWith(uint256 amount) internal returns (RhEscrow4626 escrow, uint256 shares) {
        escrow = new RhEscrow4626(IERC20(address(AAPL)));
        vm.startPrank(user);
        AAPL.approve(address(escrow), type(uint256).max);
        shares = escrow.deposit(amount, user);
        vm.stopPrank();
    }

    /// Recorded state: ERC-8056 interfaces, one shared registry acting as
    /// beacon, role holders, multiplier views consistent.
    function test_fork_rh_tokenFacts() public onlyFork {
        assertEq(block.chainid, 4663);
        assertEq(AAPL.decimals(), 18);
        assertTrue(AAPL.supportsInterface(0xa60bf13d), "IScaledUIAmount");
        assertTrue(AAPL.supportsInterface(0x4bd27648), "IScaledUIAmountNewUIMultiplier");
        assertTrue(AAPL.supportsInterface(0xd890fd71), "IScaledUIAmountBalances");
        assertFalse(AAPL.supportsInterface(0x57854fc3), "no conversion extension");

        assertEq(AAPL.ACCESS_CONTROLLED_REGISTRY(), address(REGISTRY));
        assertEq(SOXX.ACCESS_CONTROLLED_REGISTRY(), address(REGISTRY));
        assertEq(REGISTRY.implementation(), IMPL);

        assertTrue(REGISTRY.hasRole(0x00, DEFAULT_ADMIN), "DEFAULT_ADMIN_ROLE");
        assertTrue(REGISTRY.hasRole(keccak256("BEACON_UPGRADER_ROLE"), BEACON_UPGRADER));
        assertTrue(REGISTRY.hasRole(keccak256("MINTER_ROLE"), MINTER));
        assertTrue(REGISTRY.hasRole(keccak256("BURNER_ROLE"), BURNER));
        assertTrue(REGISTRY.hasRole(keccak256("ADMIN_BURNER_ROLE"), ADMIN_BURNER));
        assertTrue(REGISTRY.hasRole(keccak256("PAUSER_ROLE"), PAUSER));
        assertTrue(REGISTRY.hasRole(keccak256("TOKEN_PAUSER_ROLE"), TOKEN_PAUSER));
        assertTrue(REGISTRY.hasRole(keccak256("ORACLE_PAUSER_ROLE"), ORACLE_PAUSER));
        assertTrue(REGISTRY.hasRole(keccak256("MULTIPLIER_UPDATER_ROLE"), MULTIPLIER_UPDATER));
        assertTrue(REGISTRY.hasRole(keccak256("BLOCKER_ROLE"), BLOCKER));
        assertTrue(REGISTRY.hasRole(keccak256("MINTER_ROLE"), LIQUIDATOR_CONTRACT));
        assertTrue(REGISTRY.hasRole(keccak256("BURNER_ROLE"), LIQUIDATOR_CONTRACT));
        assertEq(MULTIPLIER_UPDATER.code.length, 0, "updater is an EOA");
        assertEq(ADMIN_BURNER.code.length, 0, "admin burner is an EOA");

        if (block.timestamp >= AAPL.effectiveAt()) assertEq(AAPL.uiMultiplier(), AAPL.newUIMultiplier());
        assertEq(AAPL.balanceOfUI(user), 100e18 * AAPL.uiMultiplier() / WAD);
        // SOXX: set to ~3.0 effective 2026-11-04 14:30 UTC, reverted to ~1.00045
        // effective 17:32 UTC (RH-6). Logged, not asserted.

        emit log_named_uint("AAPL uiMultiplier", AAPL.uiMultiplier());
        emit log_named_uint("SOXX uiMultiplier", SOXX.uiMultiplier());
        emit log_named_uint("AAPL totalSupply", AAPL.totalSupply());
        emit log_named_uint("SOXX oraclePaused", SOXX.oraclePaused() ? 1 : 0);
    }

    /// Chainlink's Robinhood feed quotes one token (equity x multiplier).
    function test_fork_rh_chainlinkFeedIsPerToken() public onlyFork {
        (, int256 answer,, uint256 updatedAt,) = AAPL_FEED.latestRoundData();
        assertEq(AAPL_FEED.decimals(), 8);
        assertGt(answer, 0);
        emit log_named_uint("AAPL feed (per token, 8dp)", uint256(answer));
        emit log_named_uint("implied equity (8dp)", uint256(answer) * WAD / AAPL.uiMultiplier());
        emit log_named_uint("feed age (s)", block.timestamp - updatedAt);
    }

    /// Full Poppie path on the real token: escrow -> token (direct route, no
    /// wrapper) priced by the v1 adapter. A Robinhood-scheduled 2:1 split
    /// activates: raw balances unchanged, router value unchanged, and the
    /// keeper's per-token push is a 0% move.
    function test_fork_rh_splitThroughRouterIsContinuous() public onlyFork {
        PoppieEulerOracle o = new PoppieEulerOracle(address(this), address(this), 3 days, 1 days);
        address[] memory b = new address[](1);
        b[0] = address(AAPL);
        uint16[] memory c = new uint16[](1);
        c[0] = 2000;
        o.configureAssets(b, c, c);
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(o), address(this), USD, 18);
        ad.registerBase(address(AAPL), 18);
        (RhEscrow4626 escrow, uint256 es) = _escrowWith(10e18);
        EulerRouter router = new EulerRouter(address(0xE7C), address(this));
        router.govSetResolvedVault(address(escrow), true);
        router.govSetConfig(address(AAPL), USD, address(ad));

        uint256 equity = 270e18;
        o.adminSetPrice(address(AAPL), uint128(equity * AAPL.uiMultiplier() / WAD));
        uint256 v0 = router.getQuote(es, address(escrow), USD);
        assertApproxEqRel(v0, 10 * equity * AAPL.uiMultiplier() / WAD, 1e12);

        uint256 mOld = AAPL.uiMultiplier();
        uint256 act = block.timestamp + 1 hours;
        vm.prank(MULTIPLIER_UPDATER);
        AAPL.updateMultiplier(mOld * 2, act);
        assertEq(AAPL.uiMultiplier(), mOld, "not active yet");
        assertEq(AAPL.newUIMultiplier(), mOld * 2);
        assertEq(AAPL.effectiveAt(), act);

        vm.warp(act);
        assertEq(AAPL.uiMultiplier(), mOld * 2);
        assertEq(AAPL.balanceOf(address(escrow)), 10e18, "raw balance unchanged");
        assertEq(router.getQuote(es, address(escrow), USD), v0, "no jump at activation");

        uint128[] memory p = new uint128[](1);
        p[0] = uint128((equity / 2) * AAPL.uiMultiplier() / WAD);
        o.keeperPushPrices(b, p);
        assertApproxEqRel(router.getQuote(es, address(escrow), USD), v0, 1e12);

        vm.prank(user);
        assertEq(escrow.redeem(es, user, user), 10e18, "same raw amount out");
    }

    /// The updater key has no bound on size or notice: the one-argument
    /// overload applies any value instantly; the scheduled one rejects only
    /// past times. Other callers are rejected.
    function test_fork_rh_multiplierUpdaterIsUnbounded() public onlyFork {
        vm.prank(MULTIPLIER_UPDATER);
        AAPL.updateMultiplier(1000e18);
        assertEq(AAPL.uiMultiplier(), 1000e18, "x1000 applied instantly");

        vm.prank(MULTIPLIER_UPDATER);
        AAPL.updateMultiplier(0.001e18, block.timestamp + 60);
        vm.warp(block.timestamp + 60);
        assertEq(AAPL.uiMultiplier(), 0.001e18, "x0.001 with 60 s notice");

        vm.prank(MULTIPLIER_UPDATER);
        vm.expectRevert(bytes("Effective time must not be in the past"));
        AAPL.updateMultiplier(2e18, block.timestamp - 1);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        AAPL.updateMultiplier(2e18);
    }

    /// Issuer risk: two keys can burn tokens from any holder, including an
    /// escrow vault, with no allowance.
    function test_fork_rh_issuerCanBurnFromEscrow() public onlyFork {
        (RhEscrow4626 escrow,) = _escrowWith(10e18);
        vm.prank(ADMIN_BURNER);
        AAPL.adminBurn(address(escrow), 4e18);
        assertEq(AAPL.balanceOf(address(escrow)), 6e18, "ADMIN_BURNER: adminBurn");
        vm.prank(BURNER);
        AAPL.burn(address(escrow), 1e18);
        assertEq(AAPL.balanceOf(address(escrow)), 5e18, "BURNER: burn");
        assertEq(AAPL.balanceOfUI(address(escrow)), 5e18 * AAPL.uiMultiplier() / WAD);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        AAPL.adminBurn(address(escrow), 1);
    }

    /// Token pause freezes escrow deposits and withdrawals of that name; escrow
    /// shares (the EVK seizure path) still move.
    function test_fork_rh_tokenPauseFreezesEscrowNotShares() public onlyFork {
        (RhEscrow4626 escrow, uint256 es) = _escrowWith(10e18);
        vm.prank(TOKEN_PAUSER);
        AAPL.pause();
        assertTrue(AAPL.tokenPaused());

        vm.startPrank(user);
        vm.expectRevert();
        escrow.redeem(1e18, user, user);
        vm.expectRevert();
        escrow.deposit(1e18, user);
        escrow.transfer(liquidator, es / 2); // seizure stand-in
        vm.stopPrank();
        assertEq(escrow.balanceOf(liquidator), es / 2);
    }

    /// One registry pause freezes every Robinhood token at once.
    function test_fork_rh_registryPauseFreezesAllTokens() public onlyFork {
        vm.prank(PAUSER);
        REGISTRY.pause();
        assertTrue(REGISTRY.paused());
        vm.startPrank(user);
        vm.expectRevert();
        AAPL.transfer(liquidator, 1e18);
        vm.stopPrank();
        assertTrue(AAPL.paused() || REGISTRY.paused());
    }

    /// Blocklisting the escrow freezes its token movements.
    function test_fork_rh_blockedEscrowCannotMoveTokens() public onlyFork {
        (RhEscrow4626 escrow,) = _escrowWith(10e18);
        address[] memory a = new address[](1);
        a[0] = address(escrow);
        vm.prank(BLOCKER);
        REGISTRY.blockAccounts(a);
        assertTrue(REGISTRY.isBlocked(address(escrow)));
        vm.prank(user);
        vm.expectRevert();
        escrow.redeem(1e18, user, user);
    }

    /// oraclePaused() is advisory only: setting it does not stop transfers.
    function test_fork_rh_oraclePauseIsAdvisory() public onlyFork {
        vm.prank(ORACLE_PAUSER);
        AAPL.pauseOracle();
        assertTrue(AAPL.oraclePaused());
        vm.prank(user);
        AAPL.transfer(liquidator, 1e18);
        assertEq(AAPL.balanceOf(liquidator), 1e18);
    }
}
