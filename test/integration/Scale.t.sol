// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";
import {ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";

import {FullStackFixture} from "../harness/FullStackFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Scale on the full stack (V2_PLAN section 8, CONTRACT_SPEC section 6 "Scale"; phase-2 gate "300+ collateral
/// gas/lens tests"): 500 collaterals listed in one hub through the real listing flow, then:
/// - `LTVList()` and a lens-equivalent walk (LTVFull + router bid/ask per collateral) over all 500;
/// - an account at EVC's 10-collateral limit borrowing (account + vault status checks through the router);
/// - a 500-asset packed push, a 500-asset plain push and a 500-asset `confirmBatch` on the live oracle.
/// The Euler lenses themselves import `reward-streams` / `permit2` paths this repo does not remap; they are
/// measured on the Arbitrum fork (POP-12). Gas is printed with `-vv`; ceilings are Arbitrum's 32M block limit.
/// Run without `--isolate`: the 500-vault setUp exceeds forge's per-test gas budget when every call is cold, so the
/// numbers here are warm. Cold per-call numbers for the oracle and steward batches are in `test/bench/`.
contract ScaleIntegrationTest is FullStackFixture {
    uint256 internal constant N = 500;
    uint256 internal constant BLOCK_GAS = 32_000_000;
    uint256 internal constant LIST_CHUNK = 100;
    uint256 internal constant ORACLE_CHUNK = 100;

    address[] internal tokens;
    IEVault[] internal escrows;

    function setUp() public override {
        super.setUp();
        _bulkList(N);
    }

    /// @dev The listing flow for `n` long-tail M1 assets, with stage 2 batched as the Safe batch would be.
    function _bulkList(uint256 n) internal {
        address[] memory ts = new address[](n);
        IPoppieEulerOracle.PriceClass[] memory pcs = new IPoppieEulerOracle.PriceClass[](n);
        IPoppieRiskSteward.CapCeilingChange[] memory cc = new IPoppieRiskSteward.CapCeilingChange[](n);
        IPoppieRiskSteward.Listing[] memory ls = new IPoppieRiskSteward.Listing[](n);
        for (uint256 i; i < n; ++i) {
            // Under --isolate every call is its own transaction in the current block: spread setUp over blocks.
            if (i % 20 == 0) vm.roll(block.number + 1);
            MockERC20 t = new MockERC20("T", "T", 18);
            vm.prank(timelock);
            routerGovernor.setApprovedToken(address(t), true);
            IEVault e = _createEscrow(address(t));
            t.mint(address(this), 1e18);
            t.approve(address(e), 1e18);
            e.deposit(1e18, deployer);
            e.setHookConfig(address(escrowHook), ESCROW_HOOKED_OPS);
            e.setGovernorAdmin(address(governor));

            tokens.push(address(t));
            escrows.push(e);
            escrowOf[address(t)] = e;
            heldBy[address(t)] = address(t);
            ts[i] = address(t);
            pcs[i] = IPoppieEulerOracle.PriceClass.M1;
            cc[i] = IPoppieRiskSteward.CapCeilingChange(address(e), steward_encode(ESCROW_CEILING_AMOUNT), 1);
            ls[i] = IPoppieRiskSteward.Listing(address(t), address(e), address(hubM1), IPoppieRiskSteward.RiskClass.M1);
        }
        // `listAssets` is chunked at 100 per call (a 250 chunk ran out of gas cold under --isolate).
        for (uint256 start; start < n; start += ORACLE_CHUNK) {
            uint256 len = n - start < ORACLE_CHUNK ? n - start : ORACLE_CHUNK;
            address[] memory tc = new address[](len);
            IPoppieEulerOracle.PriceClass[] memory pc = new IPoppieEulerOracle.PriceClass[](len);
            for (uint256 k; k < len; ++k) {
                tc[k] = ts[start + k];
                pc[k] = pcs[start + k];
            }
            vm.roll(block.number + 1);
            vm.prank(ops);
            uint256 g0 = gasleft();
            oracle.listAssets(tc, pc);
            if (start == 0) console.log("oracle.listAssets x100 (setUp)", g0 - gasleft());
        }
        vm.startPrank(ops);
        for (uint256 i; i < n; ++i) {
            if (i % 100 == 0) vm.roll(block.number + 1);
            routerGovernor.addRoute(ts[i]);
            routerGovernor.addResolvedVault(address(escrows[i]));
        }
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.prank(ops);
        steward.setCapCeiling(cc);
        // A long-tail `list` costs ~165k gas per asset: chunk at 100 per call (one Safe transaction each).
        for (uint256 start; start < n; start += LIST_CHUNK) {
            uint256 len = n - start < LIST_CHUNK ? n - start : LIST_CHUNK;
            IPoppieRiskSteward.Listing[] memory chunk = new IPoppieRiskSteward.Listing[](len);
            for (uint256 k; k < len; ++k) {
                chunk[k] = ls[start + k];
            }
            vm.roll(block.number + 1);
            vm.prank(ops);
            uint256 g1 = gasleft();
            steward.list(chunk);
            if (start == 0) console.log("steward.list x100 long tail (setUp)", g1 - gasleft());
        }

        uint128[] memory ps = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            ps[i] = 50e18;
        }
        vm.roll(block.number + 1);
        vm.prank(keeper);
        oracle.keeperPushPrices(ts, ps);
        vm.roll(block.number + 1);
        vm.prank(confirmer);
        oracle.confirmBatch(ts, ps);
        vm.roll(block.number + 1);
    }

    function _check(string memory label, uint256 g) internal pure {
        console.log(label, g);
        assertLt(g, BLOCK_GAS, label);
    }

    function test_scale_ltvListAndLensWalk() public view {
        uint256 g = gasleft();
        address[] memory list = hubM1.LTVList();
        g -= gasleft();
        assertEq(list.length, N);
        _check("LTVList() x500", g);

        g = gasleft();
        uint256 sum;
        for (uint256 i; i < list.length; ++i) {
            (uint16 b,,,,) = hubM1.LTVFull(list[i]);
            (uint256 bid,) = router.getQuotes(1e18, list[i], USD);
            sum += bid * b;
        }
        g -= gasleft();
        assertGt(sum, 0);
        _check("lens walk (LTVFull + getQuotes) x500", g);
    }

    function test_scale_tenCollateralAccountBorrowAndCheck() public {
        address b = makeAddr("whale");
        for (uint256 i; i < 10; ++i) {
            _depositCollateral(tokens[i * 50], b, 10e18, i == 0 ? hubM1 : IEVault(address(0)));
        }
        // 10 assets x 10 tokens x 50 USD x 25% = 1,250.
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = _borrowItem(hubM1, b, 1_200e6, address(feeRouter));
        items[1] = _forwardItem(hubM1, b, b);
        vm.prank(b);
        uint256 g = gasleft();
        evc.batch(items);
        g -= gasleft();
        _check("borrow batch, 10 collaterals, 500 listed", g);

        g = gasleft();
        (uint256 c, uint256 l) = hubM1.accountLiquidity(b, false);
        g -= gasleft();
        assertGt(c, l);
        _check("accountLiquidity, 10 collaterals", g);

        g = gasleft();
        hubM1.accountLiquidityFull(b, false);
        g -= gasleft();
        _check("accountLiquidityFull, 10 collaterals", g);
    }

    function test_scale_push500BothFormatsAndConfirmBatch() public {
        vm.warp(block.timestamp + 5 minutes);
        uint128[] memory ps = new uint128[](N);
        bytes memory packed;
        for (uint256 i; i < N; ++i) {
            ps[i] = 51e18;
            packed = bytes.concat(packed, PackedPrices.encode(oracle.assetId(tokens[i]), 52e18));
        }
        vm.prank(keeper);
        uint256 g = gasleft();
        oracle.keeperPushPrices(tokens, ps);
        g -= gasleft();
        _check("keeperPushPrices x500", g);

        vm.warp(block.timestamp + 5 minutes);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        g = gasleft();
        oracle.keeperPushPacked(packed);
        g -= gasleft();
        _check("keeperPushPacked x500", g);

        // Gap up 30% (beyond the 15% M1 bound): all Unconfirmed, then one confirmBatch.
        vm.warp(block.timestamp + 5 minutes);
        for (uint256 i; i < N; ++i) {
            ps[i] = 70e18;
        }
        vm.roll(block.number + 1);
        vm.prank(keeper);
        oracle.keeperPushPrices(tokens, ps);
        vm.roll(block.number + 1);
        assertEq(uint8(oracle.state(tokens[N - 1])), uint8(IPoppieEulerOracle.PriceState.Unconfirmed));
        vm.prank(confirmer);
        g = gasleft();
        oracle.confirmBatch(tokens, ps);
        g -= gasleft();
        _check("confirmBatch x500", g);
        assertEq(uint8(oracle.state(tokens[N - 1])), uint8(IPoppieEulerOracle.PriceState.Live));
    }
}
