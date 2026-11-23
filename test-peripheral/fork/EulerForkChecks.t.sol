// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {ForkUtil} from "../lib/ForkUtil.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";
import {IEVCSubset} from "../../src/peripheral/interfaces/IEVCSubset.sol";
import {ISanctionsList} from "../../src/peripheral/interfaces/ISanctionsList.sol";
import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

/// @dev Minimal interfaces to Euler's live Arbitrum deployment. Interface-only: EVK is not in the repo (POP-33).
interface IGenericFactory {
    function implementation() external view returns (address);
    function isProxy(address) external view returns (bool);
    function createProxy(address desiredImplementation, bool upgradeable, bytes memory trailingData)
        external
        returns (address);
}

interface IEVaultSubset {
    function governorAdmin() external view returns (address);
    function protocolConfigAddress() external view returns (address);
    function protocolFeeShare() external view returns (uint256);
    function protocolFeeReceiver() external view returns (address);
    function interestFee() external view returns (uint16);
    function feeReceiver() external view returns (address);
    function setFeeReceiver(address) external;
    function setHookConfig(address target, uint32 ops) external;
    function hookConfig() external view returns (address, uint32);
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
    function LTVList() external view returns (address[] memory);
}

interface IProtocolConfigSubset {
    function interestFeeRange(address vault) external view returns (uint16 minInterestFee, uint16 maxInterestFee);
    function protocolFeeConfig(address vault) external view returns (address feeReceiver, uint16 protocolFeeShare);
}

interface IEulerEarnFactorySubset {
    function supportedPerspective() external view returns (address);
    function isStrategyAllowed(address) external view returns (bool);
}

/// @dev Has code but no `isHookTarget`: EVK must refuse it as a hook target (A30 a).
contract NotAHookTarget {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice POP-12: Euler fork checks both designs rely on, against Euler's canonical Arbitrum deployment.
///         Addresses: euler-xyz/euler-interfaces `addresses/42161` (as pinned on the `scale` branch's ForkBase).
///         Interface-only, so it runs without EVK in the repo. Pin a recent block with $ARB_FORK_BLOCK unless an
///         archive RPC is configured ($ARB_RPC or $ALCHEMY_API_KEY).
contract EulerForkChecksTest is ForkUtil {
    address internal constant EVC = 0x6302ef0F34100CDDFb5489fbcB6eE1AA95CD1066;
    address internal constant EVAULT_FACTORY = 0x78Df1CF5bf06a7f27f2ACc580B934238C1b80D50;
    address internal constant EVAULT_IMPLEMENTATION = 0x832fF4011A3164ea76ceA06A313EE0B6CD72ba96;
    address internal constant PROTOCOL_CONFIG = 0x06c1Ab0A1672E8FC7F7D10BD7B869B4116D18a2c;
    address internal constant EULER_EARN_FACTORY = 0xB9B5d62B9fE9E1B505466e75817aB178A1D2ec9d;
    address internal constant EVK_FACTORY_PERSPECTIVE = 0x03a931446F5A7e7ec1D850D8eaF95Ab68Ad9089C;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant CHAINALYSIS = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;
    address internal constant ARB_GAS_INFO = 0x000000000000000000000000000000000000006C;
    address internal constant USD = address(840);

    /// @dev EVK `CONFIG_SCALE`: fee shares and LTVs are in 1e4 units.
    uint256 internal constant CONFIG_SCALE = 1e4;

    IEVaultSubset internal hub;

    function setUp() public {
        if (!_forkArbitrum()) return;
        // A hub-shaped vault from the canonical factory: USDC, priced in USD. This contract is its governor.
        // The oracle is never called here (no borrows), so the EVC address stands in for it.
        hub = IEVaultSubset(
            IGenericFactory(EVAULT_FACTORY).createProxy(address(0), false, abi.encodePacked(USDC, EVC, USD))
        );
    }

    // ── canonical deployment ──
    function test_fork_canonicalAddresses() public view {
        assertEq(IGenericFactory(EVAULT_FACTORY).implementation(), EVAULT_IMPLEMENTATION);
        assertTrue(IGenericFactory(EVAULT_FACTORY).isProxy(address(hub)));
        assertEq(hub.governorAdmin(), address(this));
        assertEq(hub.protocolConfigAddress(), PROTOCOL_CONFIG);
        assertEq(IEulerEarnFactorySubset(EULER_EARN_FACTORY).supportedPerspective(), EVK_FACTORY_PERSPECTIVE);
    }

    // ── 1. Euler Earn accepts Poppie hubs, also with a P1 hook installed ──
    function test_fork_earnAcceptsHub_plainAndWithP1() public {
        IEulerEarnFactorySubset f = IEulerEarnFactorySubset(EULER_EARN_FACTORY);
        assertTrue(f.isStrategyAllowed(address(hub)), "Earn rejects a plain factory hub");

        HubGuard g = new HubGuard(
            IEVCSubset(EVC), ISanctionsList(CHAINALYSIS), 100, 7 days, address(this), address(this), address(this)
        );
        uint32 ops = EVKOps.OP_BORROW | EVKOps.OP_FLASHLOAN | EVKOps.OP_DEPOSIT | EVKOps.OP_MINT | EVKOps.OP_SKIM
            | EVKOps.OP_VAULT_STATUS_CHECK;
        hub.setHookConfig(address(g), ops);
        (address target, uint32 got) = hub.hookConfig();
        assertEq(target, address(g));
        assertEq(got, ops);
        assertTrue(f.isStrategyAllowed(address(hub)), "Earn rejects a hub with P1 installed");
    }

    // ── 2. Euler's protocol fee share (D2, B10) ──
    function test_fork_protocolFeeShare() public view {
        (address rcv, uint16 share) = IProtocolConfigSubset(PROTOCOL_CONFIG).protocolFeeConfig(address(hub));
        (uint16 minFee, uint16 maxFee) = IProtocolConfigSubset(PROTOCOL_CONFIG).interestFeeRange(address(hub));
        console.log("protocolFeeShare (1e4 = 100%)", share);
        console.log("protocolFeeReceiver", rcv);
        console.log("interestFeeRange min", minFee);
        console.log("interestFeeRange max", maxFee);
        console.log("default interestFee on a new hub", hub.interestFee());
        assertEq(hub.protocolFeeReceiver(), rcv);
        assertLe(share, CONFIG_SCALE / 2, "protocol share above EVK's 50% cap");
        assertLe(minFee, maxFee);
    }

    /// @dev Finding: with no governor fee receiver, EVK sends 100% of the interest fee to Euler. Every hub must
    ///      have `setFeeReceiver` in its deployment batch, and the config check must verify it (POP-14).
    function test_fork_noFeeReceiver_allFeesToEuler() public {
        (, uint16 share) = IProtocolConfigSubset(PROTOCOL_CONFIG).protocolFeeConfig(address(hub));
        assertEq(hub.feeReceiver(), address(0));
        assertEq(hub.protocolFeeShare(), CONFIG_SCALE, "unset receiver: protocol takes everything");
        hub.setFeeReceiver(makeAddr("poppieReserve"));
        assertEq(hub.protocolFeeShare(), share, "receiver set: configured protocol share applies");
        console.log("protocolFeeShare with Poppie receiver set", hub.protocolFeeShare());
    }

    // ── 3. Governance gas for 300 and 500 collaterals in one hub (B9) ──
    function test_fork_ltvGas_300() public {
        _measureLtvs(300);
    }

    function test_fork_ltvGas_500() public {
        _measureLtvs(500);
    }

    function _measureLtvs(uint256 n) internal {
        uint256 total;
        uint256 maxOne;
        for (uint256 i; i < n; ++i) {
            address collateral = address(uint160(0x10000 + i));
            uint256 g0 = gasleft();
            hub.setLTV(collateral, 2500, 3000, 0);
            uint256 used = g0 - gasleft();
            total += used;
            if (used > maxOne) maxOne = used;
        }
        uint256 g1 = gasleft();
        address[] memory list = hub.LTVList();
        uint256 listGas = g1 - gasleft();
        assertEq(list.length, n);
        console.log("collaterals", n);
        console.log("  setLTV total gas", total);
        console.log("  setLTV max single call", maxOne);
        console.log("  LTVList() gas", listGas);
        // Each setLTV is a separate Safe/MultiSend call: no single call may approach Arbitrum's tx gas cap.
        assertLt(maxOne, 200_000);
    }

    // ── 4. Arbitrum gas limits (A7: configure ~14.8M and seed ~11.8M gas at 500 assets) ──
    function test_fork_arbitrumGasLimits() public {
        console.log("block.gaslimit (fork)", block.gaslimit);
        // ArbGasInfo is an ArbOS precompile with no code on a local fork: ask the RPC directly.
        bytes memory params = abi.encodePacked(
            '[{"to":"', vm.toString(ARB_GAS_INFO), '","data":"', vm.toString(abi.encodeWithSignature("getGasAccountingParams()")), '"},"latest"]'
        );
        bytes memory ret = vm.rpc("eth_call", string(params));
        (uint256 speedLimit, uint256 poolMax, uint256 maxTxGas) = abi.decode(ret, (uint256, uint256, uint256));
        console.log("ArbGasInfo speedLimitPerSecond", speedLimit);
        console.log("ArbGasInfo gasPoolMax", poolMax);
        console.log("ArbGasInfo maxTxGasLimit", maxTxGas);
        assertGe(maxTxGas, 14_800_000, "A7: 500-asset configure does not fit one tx");
    }

    // ── EVK hook behaviours checkable without EVK in the repo (partial A30 a, e; full check is POP-33) ──
    function test_fork_hookTargetMustImplementIsHookTarget() public {
        NotAHookTarget bad = new NotAHookTarget();
        vm.expectRevert();
        hub.setHookConfig(address(bad), EVKOps.OP_BORROW);
    }

    function test_fork_opVaultStatusCheckIsHighestOpBit() public {
        HubGuard g = new HubGuard(
            IEVCSubset(EVC), ISanctionsList(CHAINALYSIS), 100, 7 days, address(this), address(this), address(this)
        );
        hub.setHookConfig(address(g), EVKOps.OP_VAULT_STATUS_CHECK);
        vm.expectRevert(); // OP_MAX_VALUE = 1 << 15: the copied constants end at the right bit
        hub.setHookConfig(address(g), EVKOps.OP_VAULT_STATUS_CHECK << 1);
        hub.setHookConfig(address(0), 0); // removal restores stock behaviour (A30 g)
        (address t, uint32 o) = hub.hookConfig();
        assertEq(t, address(0));
        assertEq(o, 0);
    }
}
