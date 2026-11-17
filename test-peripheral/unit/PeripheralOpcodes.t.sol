// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Opcodes} from "../lib/Opcodes.sol";
import {P3Base} from "../lib/P3Base.sol";
import {MockEVC, MockSanctions} from "../lib/Mocks.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";
import {EscrowGuard} from "../../src/peripheral/EscrowGuard.sol";
import {KeeperForwarder} from "../../src/peripheral/KeeperForwarder.sol";
import {RouterGovernor} from "../../src/peripheral/RouterGovernor.sol";
import {PoppieEulerAdapter} from "../../src/PoppieEulerAdapter.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {IEulerRouterSubset} from "../../src/peripheral/interfaces/IEulerRouterSubset.sol";
import {IAdapterSubset} from "../../src/peripheral/interfaces/IAdapterSubset.sol";
import {IFactorySubset} from "../../src/peripheral/interfaces/IFactoryAndAssetSubset.sol";
import {IEVCSubset} from "../../src/peripheral/interfaces/IEVCSubset.sol";
import {ISanctionsList} from "../../src/peripheral/interfaces/ISanctionsList.sol";

/// @dev No custody, no upgrades: deployed runtime code has no DELEGATECALL/CALLCODE/SELFDESTRUCT/CREATE*,
///      and holds no ETH.
contract PeripheralOpcodesTest is P3Base {
    function _assertClean(address c) internal {
        assertGt(c.code.length, 0);
        (bool found, uint256 pos, uint8 op) = Opcodes.findForbidden(c.code);
        if (found) emit log_named_uint(string.concat("forbidden opcode at ", vm.toString(pos)), op);
        assertFalse(found, "forbidden opcode");
        assertEq(c.balance, 0);
    }

    function test_P3_clean() public {
        _assertClean(address(g));
    }

    function test_P2_clean() public {
        _assertClean(
            address(
                new EscrowGuard(
                    IEVCSubset(address(new MockEVC())), ISanctionsList(address(new MockSanctions())), 1 hours, 3, 1 days, safe, guardian, guardian, guardian
                )
            )
        );
    }

    function test_P4_clean() public {
        _assertClean(address(new KeeperForwarder(IPoppieEulerOracle(address(oracle)), safe, guardian, 2, 1 days)));
    }

    function test_P5_clean() public {
        PoppieEulerAdapter ad = new PoppieEulerAdapter(address(oracle), safe, address(840), 18);
        _assertClean(
            address(
                new RouterGovernor(IEulerRouterSubset(address(1)), IAdapterSubset(address(ad)), IFactorySubset(address(1)), safe, guardian)
            )
        );
    }

    /// @dev No `initialize` entry point on any peripheral contract.
    function test_noInitializer() public {
        bytes4 sel = bytes4(keccak256("initialize()"));
        (bool ok,) = address(g).call(abi.encodePacked(sel));
        assertFalse(ok, "P3 has no fallback, so unknown selectors revert");
    }

    function test_P1_clean() public {
        _assertClean(
            address(
                new HubGuard(IEVCSubset(address(new MockEVC())), ISanctionsList(address(new MockSanctions())), 100, 1 days, safe, guardian, guardian)
            )
        );
    }
}
