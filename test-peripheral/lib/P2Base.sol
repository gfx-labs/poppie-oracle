// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MockVault, MockEVC, MockSanctions} from "./Mocks.sol";
import {EscrowGuard} from "../../src/peripheral/EscrowGuard.sol";
import {IEVCSubset} from "../../src/peripheral/interfaces/IEVCSubset.sol";
import {ISanctionsList} from "../../src/peripheral/interfaces/ISanctionsList.sol";
import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

abstract contract P2Base is Test {
    uint32 internal constant ESCROW_OPS =
        EVKOps.OP_DEPOSIT | EVKOps.OP_MINT | EVKOps.OP_SKIM | EVKOps.OP_WITHDRAW | EVKOps.OP_REDEEM;
    uint32 internal constant ALL_OPS = (1 << 15) - 1;
    uint256 internal constant MAX_LEN = 4 hours;
    uint256 internal constant MAX_PER_DAY = 3;
    uint256 internal constant DAY0 = 1_699_920_000; // a UTC midnight

    MockEVC internal evc;
    MockSanctions internal sanc;
    EscrowGuard internal g;
    MockVault internal e1; // group G
    MockVault internal e2; // group G
    MockVault internal e3; // group H

    address internal ops = makeAddr("msOps");
    address internal guardian = makeAddr("guardian");
    address internal scheduler = makeAddr("scheduler");
    address internal denylister = makeAddr("denylister");
    address internal G = makeAddr("groupBacked");
    address internal H = makeAddr("groupOther");
    address internal user = makeAddr("user");

    function setUp() public virtual {
        vm.warp(DAY0 + 10 hours);
        evc = new MockEVC();
        sanc = new MockSanctions();
        g = new EscrowGuard(
            IEVCSubset(address(evc)), ISanctionsList(address(sanc)), MAX_LEN, MAX_PER_DAY, 7 days, ops, guardian, scheduler, denylister
        );
        e1 = new MockVault(address(0));
        e2 = new MockVault(address(0));
        e3 = new MockVault(address(0));
        e1.setHookConfig(address(g), ESCROW_OPS);
        e2.setHookConfig(address(g), ESCROW_OPS);
        e3.setHookConfig(address(g), ESCROW_OPS);
        vm.startPrank(ops);
        g.setEscrow(address(e1), G);
        g.setEscrow(address(e2), G);
        g.setEscrow(address(e3), H);
        vm.stopPrank();
        // user holds shares in every escrow (deposited before any window)
        vm.startPrank(user);
        e1.deposit(100, user);
        e2.deposit(100, user);
        e3.deposit(100, user);
        vm.stopPrank();
    }

    function _u40(uint256 x) internal pure returns (uint40) {
        return SafeCast.toUint40(x);
    }

    function _addWindow(address grp, uint256 start, uint256 end) internal {
        vm.prank(scheduler);
        g.addWindow(grp, _u40(start), _u40(end));
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }
}
