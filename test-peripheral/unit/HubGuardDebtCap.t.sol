// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {P1Base} from "../lib/P1Base.sol";
import {MockVault} from "../lib/Mocks.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";

contract HubGuardDebtCapTest is P1Base {
    address internal other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        vm.startPrank(ops);
        g.setHub(address(hub), LIMIT, WINDOW, 0, address(0), 1); // no fee: isolate the cap
        g.setDebtCap(address(hub), 100e6);
        vm.stopPrank();
    }

    function test_withinCap_passes() public {
        _batch(user, 100e6, 0);
        assertEq(hub.debtOf(user), 100e6);
    }

    function test_overCap_reverts() public {
        _batchReverts(user, _calls(_b(100e6 + 1, user)), abi.encodeWithSelector(HubGuard.DebtCapExceeded.selector, user));
    }

    function test_capIsCumulativeAcrossBatches() public {
        _batch(user, 60e6, 0);
        _batchReverts(user, _calls(_b(41e6, user)), abi.encodeWithSelector(HubGuard.DebtCapExceeded.selector, user));
        _batch(user, 40e6, 0);
    }

    function test_capIsPerAccount() public {
        _batch(user, 100e6, 0);
        _batch(other, 100e6, 0);
    }

    function test_repayInSameBatch_counts() public {
        vm.prank(user);
        hub.batch(_calls(_b(150e6, user), abi.encodeCall(MockVault.repay, (50e6, user))));
        assertEq(hub.debtOf(user), 100e6);
    }

    function test_overCapAccount_canStillRepay() public {
        _batch(user, 100e6, 0);
        hub.setDebt(user, 200e6); // e.g. interest accrued past the cap
        vm.prank(user);
        hub.batch(_calls(abi.encodeCall(MockVault.repay, (10e6, user))));
        _batchReverts(user, _calls(_b(1, user)), abi.encodeWithSelector(HubGuard.DebtCapExceeded.selector, user));
    }

    function test_capOff_noCheck_noAccountsRecorded() public {
        vm.prank(ops);
        g.setDebtCap(address(hub), 0);
        _batch(user, 500e6, 0);
    }

    function test_setDebtCap_onlyOwner() public {
        vm.prank(guardian);
        vm.expectRevert(HubGuard.Unauthorized.selector);
        g.setDebtCap(address(hub), 1);
    }

    function test_listClearedBetweenBatches() public {
        _batch(user, 100e6, 0); // user at cap
        hub.setDebt(user, 1_000e6); // user now over cap, but does not borrow in the next batch
        _batch(other, 10e6, 0); // must not be blamed on user's stale entry
    }
}
