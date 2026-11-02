// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

import {IPoppieRiskSteward} from "../../src/interfaces/IPoppieRiskSteward.sol";

import {StewardFixture} from "../harness/StewardFixture.sol";

/// @notice Steward batch gas with 500 collaterals in one hub (V2_PLAN.md section 8 "Scale", POP-11 done-when):
/// a 500-asset `overrideLTV`, a 500-pair `cancelRamp` (after a 500-asset `lowerLiquidationLTV`), a 500-vault
/// `raiseCaps`, a 100-asset long-tail `list`, and an 80-asset blue-chip batch fanned out across the 4 hubs. Each call must fit in
/// Arbitrum's 32M block gas limit. Numbers are printed with `-vv`.
///
/// Reported gas is the execution gas measured around the call; calldata and the 21k base are added for the
/// transaction estimate. Run with `--isolate` for cold-storage numbers.
contract StewardGasTest is StewardFixture {
    uint256 internal constant N = 500;
    uint256 internal constant BLOCK_GAS = 32_000_000;

    address[] internal tokens;
    IEVault[] internal escrows;

    function setUp() public override {
        super.setUp();
        IPoppieRiskSteward.Listing[] memory l = new IPoppieRiskSteward.Listing[](N);
        for (uint256 i; i < N; ++i) {
            (address token, IEVault escrow) = _newEscrow();
            tokens.push(token);
            escrows.push(escrow);
            l[i] = IPoppieRiskSteward.Listing(token, address(escrow), address(hubM1), IPoppieRiskSteward.RiskClass.M1);
        }
        vm.prank(ops);
        steward.list(l);
        assertEq(hubM1.LTVList().length, N);
    }

    function _report(string memory label, uint256 gasUsed, bytes memory data) internal pure returns (uint256 tx_) {
        uint256 calldataGas;
        for (uint256 i; i < data.length; ++i) {
            calldataGas += data[i] == 0 ? 4 : 16;
        }
        tx_ = gasUsed + calldataGas + 21_000;
        console.log(label, tx_);
        assertLt(tx_, BLOCK_GAS, label);
    }

    function test_gas_overrideLTV500() public {
        IPoppieRiskSteward.BorrowLtvChange[] memory c = new IPoppieRiskSteward.BorrowLtvChange[](N);
        for (uint256 i; i < N; ++i) {
            c[i] = IPoppieRiskSteward.BorrowLtvChange(address(hubM1), tokens[i], 2000);
        }
        vm.prank(ops);
        uint256 g = gasleft();
        steward.overrideLTV(c);
        g -= gasleft();
        _report("overrideLTV x500", g, abi.encodeCall(IPoppieRiskSteward.overrideLTV, (c)));
    }

    function test_gas_lowerLiquidationThenCancelRamp500() public {
        IPoppieRiskSteward.LiquidationLtvChange[] memory c = new IPoppieRiskSteward.LiquidationLtvChange[](N);
        IPoppieRiskSteward.RampRef[] memory r = new IPoppieRiskSteward.RampRef[](N);
        for (uint256 i; i < N; ++i) {
            c[i] = IPoppieRiskSteward.LiquidationLtvChange(address(hubM1), tokens[i], 2400, 72 hours);
            r[i] = IPoppieRiskSteward.RampRef(address(hubM1), tokens[i]);
        }
        vm.prank(tightener);
        uint256 g = gasleft();
        steward.lowerLiquidationLTV(c);
        g -= gasleft();
        _report("lowerLiquidationLTV x500", g, abi.encodeCall(IPoppieRiskSteward.lowerLiquidationLTV, (c)));

        vm.warp(block.timestamp + 1 days);
        vm.prank(ops);
        g = gasleft();
        steward.cancelRamp(r);
        g -= gasleft();
        _report("cancelRamp x500", g, abi.encodeCall(IPoppieRiskSteward.cancelRamp, (r)));
        assertEq(hubM1.LTVLiquidation(address(escrows[N - 1])), 2900);
    }

    function test_gas_raiseCaps500() public {
        IPoppieRiskSteward.CapChange[] memory c = new IPoppieRiskSteward.CapChange[](N);
        for (uint256 i; i < N; ++i) {
            c[i] = IPoppieRiskSteward.CapChange(address(escrows[i]), escrowSupplyCeiling, 1);
        }
        vm.prank(loosener);
        uint256 g = gasleft();
        steward.raiseCaps(c);
        g -= gasleft();
        _report("raiseCaps x500", g, abi.encodeCall(IPoppieRiskSteward.raiseCaps, (c)));
    }

    function test_gas_list100() public {
        uint256 n = 100;
        IPoppieRiskSteward.Listing[] memory l = new IPoppieRiskSteward.Listing[](n);
        for (uint256 i; i < n; ++i) {
            (address token, IEVault escrow) = _newEscrow();
            l[i] = IPoppieRiskSteward.Listing(token, address(escrow), address(hubM2), IPoppieRiskSteward.RiskClass.M2);
        }
        vm.prank(ops);
        uint256 g = gasleft();
        steward.list(l);
        g -= gasleft();
        _report("list x100 (long tail)", g, abi.encodeCall(IPoppieRiskSteward.list, (l)));
    }

    /// @dev Blue chips fan out to all 4 hubs: about 330k gas per listed asset, so a blue-chip `list` must be chunked
    /// at <= 80 assets per call (100 measured 33.2M). The listing-batch generator (POP-14) chunks accordingly.
    /// The override of the same 80 assets (320 setLTV calls) is far cheaper.
    function test_gas_blueChip80x4Hubs() public {
        uint256 n = 80;
        IPoppieRiskSteward.Listing[] memory l = new IPoppieRiskSteward.Listing[](n);
        IPoppieRiskSteward.BorrowLtvChange[] memory c = new IPoppieRiskSteward.BorrowLtvChange[](n);
        for (uint256 i; i < n; ++i) {
            (address token, IEVault escrow) = _newEscrow();
            l[i] = IPoppieRiskSteward.Listing(
                token, address(escrow), address(prime), IPoppieRiskSteward.RiskClass.BlueChip
            );
            c[i] = IPoppieRiskSteward.BorrowLtvChange(address(prime), token, 3000);
        }
        vm.prank(ops);
        uint256 g = gasleft();
        steward.list(l);
        g -= gasleft();
        _report("list x80 (blue chip, 4 hubs)", g, abi.encodeCall(IPoppieRiskSteward.list, (l)));

        vm.prank(ops);
        g = gasleft();
        steward.overrideLTV(c);
        g -= gasleft();
        _report("overrideLTV x80 blue chip (320 setLTV)", g, abi.encodeCall(IPoppieRiskSteward.overrideLTV, (c)));
    }
}
