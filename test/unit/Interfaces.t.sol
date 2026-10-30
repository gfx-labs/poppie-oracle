// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {
    IEVault,
    IERC20 as IEVKERC20,
    IToken,
    IERC4626 as IEVKERC4626,
    IVault as IEVKVault,
    IBorrowing,
    ILiquidation
} from "evk/EVault/IEVault.sol";
import {IVault as IEVCVault} from "ethereum-vault-connector/interfaces/IVault.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import "evk/EVault/shared/Constants.sol";
import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IPoppieEulerAdapter} from "../../src/interfaces/IPoppieEulerAdapter.sol";
import {IPoppieHubHook, MAX_BORROW_PAUSE, MAX_LIQUIDATION_PAUSE} from "../../src/interfaces/IPoppieHubHook.sol";
import {IPoppieEscrowHook, MAX_DEPOSIT_PAUSE} from "../../src/interfaces/IPoppieEscrowHook.sol";
import {IPoppieBalanceWrapper} from "../../src/interfaces/IPoppieBalanceWrapper.sol";
import {IPoppieWrapperFactory} from "../../src/interfaces/IPoppieWrapperFactory.sol";
import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";
import {HUB_HOOKED_OPS, ESCROW_HOOKED_OPS} from "../../src/hooks/HookOps.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";

import {PoppieTestBase} from "../harness/PoppieTestBase.sol";

contract PackedPricesHarness {
    function decode(bytes calldata data, uint256 index) external pure returns (uint16, uint96) {
        return PackedPrices.decode(data, index);
    }

    function entryCount(bytes calldata data) external pure returns (uint256) {
        return PackedPrices.entryCount(data);
    }

    function isValidLength(bytes calldata data) external pure returns (bool) {
        return PackedPrices.isValidLength(data);
    }
}

/// @notice Pins the interface facts other contracts rely on: hook selectors match what EVK forwards, hook
/// bitmasks, and the packed push format. Cross-checked against docs/CONTRACT_SPEC.md sections 3.1, 3.4, 3.5, 3.9.
contract InterfacesTest is PoppieTestBase {
    PackedPricesHarness internal packed = new PackedPricesHarness();

    // -- Hook entry points are the selectors EVK forwards to the hook target ---------------------

    function test_hubHookSelectorsMatchEVK() public pure {
        assertEq(IPoppieHubHook.borrow.selector, IBorrowing.borrow.selector);
        assertEq(IPoppieHubHook.liquidate.selector, ILiquidation.liquidate.selector);
        assertEq(IPoppieHubHook.flashLoan.selector, IBorrowing.flashLoan.selector);
        assertEq(IPoppieHubHook.checkVaultStatus.selector, IEVCVault.checkVaultStatus.selector);
        assertEq(IHookTarget.isHookTarget.selector, bytes4(0x87439e04));
    }

    function test_escrowHookSelectorsMatchEVK() public pure {
        assertEq(IPoppieEscrowHook.deposit.selector, IEVKERC4626.deposit.selector);
        assertEq(IPoppieEscrowHook.mint.selector, IEVKERC4626.mint.selector);
        assertEq(IPoppieEscrowHook.skim.selector, IEVKVault.skim.selector);
        assertEq(IPoppieEscrowHook.transfer.selector, IEVKERC20.transfer.selector);
        // OP_TRANSFER is also reached through transferFrom and transferFromMax, with their own selectors.
        assertEq(IPoppieEscrowHook.transferFrom.selector, IEVKERC20.transferFrom.selector);
        assertEq(IPoppieEscrowHook.transferFromMax.selector, IToken.transferFromMax.selector);
    }

    // Compile-time inheritance checks: these conversions only compile if the interface extends the base.
    function _asPriceOracle(IPoppieEulerAdapter a) internal pure returns (IPriceOracle) {
        return a;
    }

    function _asErc4626(IPoppieBalanceWrapper w) internal pure returns (IERC4626) {
        return w;
    }

    function _asHookTarget(IPoppieHubHook h, IPoppieEscrowHook e) internal pure returns (IHookTarget, IHookTarget) {
        return (h, e);
    }

    function test_registryViewSelectors() public pure {
        // The registry views PoppieRouterGovernor, PoppieEscrowHook and PoppieRiskSteward read.
        assertEq(IPoppieWrapperFactory.isWrapper.selector, bytes4(keccak256("isWrapper(address)")));
        assertEq(IPoppieWrapperFactory.wrapperOf.selector, bytes4(keccak256("wrapperOf(address)")));
        assertEq(IPoppieWrapperFactory.dividendRecipient.selector, bytes4(keccak256("dividendRecipient()")));
        assertEq(IPoppieBalanceWrapper.sweep.selector, bytes4(keccak256("sweep(address)")));
    }

    function test_wrapperFactorySelectors() public pure {
        assertEq(IPoppieWrapperFactory.createWrapper.selector, bytes4(keccak256("createWrapper(address,uint256)")));
    }

    /// Pause and unpause functions are batched (arrays of vaults); MS_OPS can end any pause early.
    function test_pauseSelectorsAreBatched() public pure {
        assertEq(IPoppieHubHook.pauseBorrows.selector, bytes4(keccak256("pauseBorrows(address[],uint40)")));
        assertEq(IPoppieHubHook.unpauseBorrows.selector, bytes4(keccak256("unpauseBorrows(address[])")));
        assertEq(IPoppieHubHook.pauseLiquidations.selector, bytes4(keccak256("pauseLiquidations(address[],uint40)")));
        assertEq(IPoppieHubHook.unpauseLiquidations.selector, bytes4(keccak256("unpauseLiquidations(address[])")));
        assertEq(IPoppieEscrowHook.pauseDeposits.selector, bytes4(keccak256("pauseDeposits(address[],uint40)")));
        assertEq(IPoppieEscrowHook.unpauseDeposits.selector, bytes4(keccak256("unpauseDeposits(address[])")));
    }

    function test_stewardSelectors() public pure {
        assertEq(IPoppieRiskSteward.promote.selector, bytes4(keccak256("promote(address)")));
        assertEq(IPoppieRiskSteward.demote.selector, bytes4(keccak256("demote(address,uint8,address)")));
        assertEq(IPoppieRiskSteward.addHub.selector, bytes4(keccak256("addHub(address,uint8)")));
        assertEq(
            IPoppieRiskSteward.setCapCeiling.selector, bytes4(keccak256("setCapCeiling((address,uint16,uint16)[])"))
        );
        assertEq(IPoppieRiskSteward.capCeilings.selector, bytes4(keccak256("capCeilings(address)")));
    }

    function test_oracleViewSelectors() public pure {
        assertEq(IPoppieEulerOracle.state.selector, bytes4(keccak256("state(address)")));
        assertEq(IPoppieEulerOracle.getQuoteData.selector, bytes4(keccak256("getQuoteData(address)")));
        assertEq(IPoppieEulerOracle.keeperPushPacked.selector, bytes4(keccak256("keeperPushPacked(bytes)")));
        assertEq(
            IPoppieEulerOracle.keeperPushPrices.selector, bytes4(keccak256("keeperPushPrices(address[],uint128[])"))
        );
    }

    // -- Hook bitmasks ---------------------------------------------------------------------------

    function test_hookMasks() public pure {
        // Hub: borrow, liquidate, flash loan, vault status check.
        assertEq(HUB_HOOKED_OPS, (1 << 6) | (1 << 11) | (1 << 12) | (1 << 14));
        // Escrow: deposit, mint, skim, transfer.
        assertEq(ESCROW_HOOKED_OPS, (1 << 0) | (1 << 1) | (1 << 5) | (1 << 4));
        // Withdraw, redeem, repay, pullDebt are never hooked.
        uint32 never = OP_WITHDRAW | OP_REDEEM | OP_REPAY | OP_REPAY_WITH_SHARES | OP_PULL_DEBT;
        assertEq(HUB_HOOKED_OPS & never, 0);
        assertEq(ESCROW_HOOKED_OPS & never, 0);
        assertEq(HUB_HOOKED_OPS & (OP_DEPOSIT | OP_MINT), 0);
        assertEq(ESCROW_HOOKED_OPS & OP_LIQUIDATE, 0);
    }

    function test_hookMasksAreAcceptedAndReadBackByEVK() public {
        address hook = makeAddr("hook");
        vm.mockCall(hook, abi.encodeCall(IHookTarget.isHookTarget, ()), abi.encode(IHookTarget.isHookTarget.selector));

        IEVault hub = _createHub();
        hub.setHookConfig(hook, HUB_HOOKED_OPS);
        (address target, uint32 ops) = hub.hookConfig();
        assertEq(target, hook);
        assertEq(ops, HUB_HOOKED_OPS);

        IEVault escrow = _createEscrow(address(stock));
        escrow.setHookConfig(hook, ESCROW_HOOKED_OPS);
        (target, ops) = escrow.hookConfig();
        assertEq(target, hook);
        assertEq(ops, ESCROW_HOOKED_OPS);
    }

    function test_pauseCaps() public pure {
        assertEq(MAX_BORROW_PAUSE, 24 hours);
        assertEq(MAX_DEPOSIT_PAUSE, 24 hours);
        assertEq(MAX_LIQUIDATION_PAUSE, 6 hours);
    }

    // -- Packed push format: uint16 id | uint96 price, 14 bytes ----------------------------------

    function test_packedKnownVector() public pure {
        bytes memory entry = PackedPrices.encode(0x0102, 0x030405060708090a0b0c0d0e);
        assertEq(entry.length, 14);
        assertEq(entry, hex"0102030405060708090a0b0c0d0e");
    }

    function testFuzz_packedRoundTrip(uint16 id0, uint96 price0, uint16 id1, uint96 price1) public view {
        bytes memory data = bytes.concat(PackedPrices.encode(id0, price0), PackedPrices.encode(id1, price1));
        assertEq(data.length, 28);
        assertTrue(packed.isValidLength(data));
        assertEq(packed.entryCount(data), 2);

        (uint16 a, uint96 b) = packed.decode(data, 0);
        assertEq(a, id0);
        assertEq(b, price0);
        (a, b) = packed.decode(data, 1);
        assertEq(a, id1);
        assertEq(b, price1);
    }

    function test_packedLengthValidation() public view {
        assertTrue(packed.isValidLength(""));
        assertFalse(packed.isValidLength(new bytes(13)));
        assertFalse(packed.isValidLength(new bytes(15)));
        // A 500-asset refresh is 7,000 bytes.
        assertEq(packed.entryCount(new bytes(7000)), 500);
    }

    // -- Enums used across contracts --------------------------------------------------------------

    function test_enumOrdering() public pure {
        // Closed is the zero value so an unset state fails closed.
        assertEq(uint8(IPoppieEulerOracle.PriceState.Closed), 0);
        assertEq(uint8(IPoppieEulerOracle.PriceState.Unconfirmed), 1);
        assertEq(uint8(IPoppieEulerOracle.PriceState.Live), 2);
        // Price class and risk class use the same ordering: blue chip, M1, M2, M3.
        assertEq(uint8(IPoppieEulerOracle.PriceClass.M3), 3);
        assertEq(uint8(IPoppieRiskSteward.RiskClass.M3), 3);
    }
}
