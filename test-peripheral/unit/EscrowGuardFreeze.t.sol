// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P2Base} from "../lib/P2Base.sol";
import {EscrowGuard} from "../../src/peripheral/EscrowGuard.sol";
import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

contract EscrowGuardFreezeTest is P2Base {
    address internal liq = makeAddr("liq");
    address internal friend = makeAddr("friend");

    function setUp() public override {
        super.setUp();
        e1.setHookConfig(address(g), ESCROW_OPS | EVKOps.OP_TRANSFER);
        vm.prank(denylister);
        g.freeze(_arr(user));
    }

    function _frozenErr(address a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EscrowGuard.Frozen.selector, a);
    }

    function test_frozen_blocksExitsAndTransfers() public {
        vm.startPrank(user);
        vm.expectRevert(_frozenErr(user));
        e1.withdraw(1, user, user);
        vm.expectRevert(_frozenErr(user));
        e1.redeem(1, user, user);
        vm.expectRevert(_frozenErr(user));
        // forge-lint: disable-next-line(erc20-unchecked-transfer) expected to revert
        e1.transfer(friend, 1);
        vm.expectRevert(_frozenErr(user));
        e1.transferFromMax(user, friend);
        vm.stopPrank();
        vm.prank(friend); // approved spender pulling from a frozen account
        vm.expectRevert(_frozenErr(user));
        // forge-lint: disable-next-line(erc20-unchecked-transfer) expected to revert
        e1.transferFrom(user, friend, 1);
    }

    function test_frozen_viaEvcOwner_coversSubAccounts() public {
        address sub = address(uint160(user) ^ 3);
        evc.setOwner(sub, user);
        vm.prank(sub);
        e1.deposit(10, sub);
        vm.prank(sub);
        vm.expectRevert(_frozenErr(user));
        e1.withdraw(1, sub, sub);
        vm.prank(sub);
        vm.expectRevert(_frozenErr(user));
        // forge-lint: disable-next-line(erc20-unchecked-transfer) expected to revert
        e1.transfer(friend, 1);
    }

    function test_seizure_passesWhileFrozen() public {
        evc.setControlCollateral(true);
        vm.startPrank(user);
        assertTrue(e1.transfer(liq, 10));
        assertTrue(e1.transferFrom(user, liq, 10));
        e1.transferFromMax(user, liq);
        vm.stopPrank();
        assertEq(e1.balanceOf(liq), 100);
    }

    function test_others_unaffected() public {
        vm.startPrank(friend);
        e1.deposit(10, friend);
        assertTrue(e1.transfer(user, 5)); // receiving is allowed
        e1.withdraw(1, friend, friend);
        vm.stopPrank();
    }

    function test_frozen_canStillDepositAndReceive() public {
        vm.prank(user);
        e1.deposit(1, user);
    }

    function test_freeze_addOnly_ownerUnfreezes() public {
        vm.prank(denylister);
        vm.expectRevert(EscrowGuard.Unauthorized.selector);
        g.unfreeze(user);
        vm.prank(guardian);
        vm.expectRevert(EscrowGuard.Unauthorized.selector);
        g.freeze(_arr(friend));
        vm.prank(ops);
        g.unfreeze(user);
        vm.prank(user);
        e1.withdraw(1, user, user);
    }

    function test_transferNotHooked_freezeOnlyCoversExits() public {
        e1.setHookConfig(address(g), ESCROW_OPS);
        vm.prank(user);
        assertTrue(e1.transfer(friend, 1));
        vm.prank(user);
        vm.expectRevert(_frozenErr(user));
        e1.withdraw(1, user, user);
    }

    /// @dev Caller extraction trusts the vault to append 20 bytes; a direct caller can forge them, but the
    ///      transfer hooks are view-only, so a forged call can at most read the freeze list.
    function test_directHookCall_isReadOnly() public {
        bytes memory forged = abi.encodePacked(abi.encodeWithSignature("transfer(address,uint256)", friend, 1), user);
        (bool ok, bytes memory ret) = address(g).call(forged);
        assertFalse(ok);
        assertEq(ret, _frozenErr(user));
        (ok,) = address(g).call(abi.encodePacked(abi.encodeWithSignature("transfer(address,uint256)", friend, 1), friend));
        assertTrue(ok);
        assertTrue(g.frozen(user)); // nothing changed
    }
}
