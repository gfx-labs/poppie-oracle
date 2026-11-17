// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkUtil} from "../lib/ForkUtil.sol";
import {MockVault} from "../lib/Mocks.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";
import {IEVCSubset} from "../../src/peripheral/interfaces/IEVCSubset.sol";
import {ISanctionsList} from "../../src/peripheral/interfaces/ISanctionsList.sol";
import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

/// @dev Real Chainalysis oracle on Arbitrum + a real EVC (lib copy, deployed on the fork). Hub is MockVault
///      (EVK deferred to phase E).
contract HubGuardSanctionsForkTest is ForkUtil {
    ISanctionsList internal constant CHAINALYSIS = ISanctionsList(0x40C57923924B5c5c5455c48D93317139ADDaC8fb);
    address internal constant SANCTIONED = 0x098B716B8Aaf21512996dC57EB0615e2383E2f96; // Ronin exploiter (OFAC)

    HubGuard internal g;
    MockVault internal hub;
    EthereumVaultConnector internal evc;
    address internal user = makeAddr("user");

    function setUp() public {
        if (!_forkArbitrum()) return;
        evc = new EthereumVaultConnector();
        g = new HubGuard(IEVCSubset(address(evc)), CHAINALYSIS, 100, 7 days, address(this), address(this), address(this));
        hub = new MockVault(address(0));
        hub.setHookConfig(address(g), EVKOps.OP_BORROW | EVKOps.OP_DEPOSIT | EVKOps.OP_VAULT_STATUS_CHECK);
        g.setHub(address(hub), type(uint128).max, 1 hours, 0, address(0), 0);
    }

    function test_fork_listIsLive() public view {
        assertTrue(CHAINALYSIS.isSanctioned(SANCTIONED));
        assertFalse(CHAINALYSIS.isSanctioned(user));
        assertTrue(g.isBlocked(SANCTIONED));
    }

    function test_fork_sanctionedBorrowerBlocked() public {
        assertEq(evc.getAccountOwner(SANCTIONED), address(0)); // unregistered: screened directly (A21)
        vm.prank(SANCTIONED);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, SANCTIONED));
        hub.borrow(1e6, user);
    }

    function test_fork_sanctionedReceiverAndDepositorBlocked() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, SANCTIONED));
        hub.borrow(1e6, SANCTIONED);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, SANCTIONED));
        hub.deposit(1e6, SANCTIONED);
        vm.stopPrank();
        vm.prank(SANCTIONED);
        vm.expectRevert(abi.encodeWithSelector(HubGuard.Blocked.selector, SANCTIONED));
        hub.deposit(1e6, user);
    }

    function test_fork_cleanUserPasses() public {
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(MockVault.borrow, (1e6, user));
        vm.prank(user);
        hub.batch(c);
    }
}
