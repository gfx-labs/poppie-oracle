// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {IPoppieBalanceWrapper} from "../../src/interfaces/IPoppieBalanceWrapper.sol";

import {WrapperFixture} from "../harness/WrapperFixture.sol";

/// @notice First-depositor (donation) attack on a freshly created wrapper, including with a 1-wei seed:
/// the attacker deposits, donates to inflate the share price, the victim deposits, then both redeem.
/// The attack must never profit, and the victim's loss is bounded by one share's worth of rounding.
contract WrapperInflationFuzzTest is WrapperFixture {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function testFuzz_donationAttackNeverProfits(
        uint256 seed,
        uint256 attackDeposit,
        uint256 donation,
        uint256 victimDeposit
    ) public {
        seed = bound(seed, 1, 1e18);
        attackDeposit = bound(attackDeposit, 1, 1e30);
        donation = bound(donation, 0, 1e30);
        victimDeposit = bound(victimDeposit, 1, 1e30);

        PoppieBalanceWrapper w = _createWrapper(address(stock), seed);

        // Attacker: deposit, then donate directly to the wrapper.
        uint256 attackerShares = _deposit(w, attacker, attackDeposit);
        stock.mint(attacker, donation);
        vm.prank(attacker);
        stock.transfer(address(w), donation);

        // Victim deposits. A deposit worth less than one share reverts instead of minting nothing.
        stock.mint(victim, victimDeposit);
        vm.startPrank(victim);
        stock.approve(address(w), victimDeposit);
        uint256 victimShares;
        try w.deposit(victimDeposit, victim) returns (uint256 s) {
            victimShares = s;
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoppieBalanceWrapper.ZeroSharesMinted.selector);
        }
        vm.stopPrank();

        // Share value before the victim's deposit bounds the victim's rounding loss.
        uint256 victimOut;
        if (victimShares != 0) {
            vm.prank(victim);
            victimOut = w.redeem(victimShares, victim, victim);
            uint256 maxLoss = (seed + attackDeposit + donation) / 1e6 + 2;
            assertGe(victimOut + maxLoss, victimDeposit, "victim loss above one share");
        }

        vm.prank(attacker);
        uint256 attackerOut = w.redeem(attackerShares, attacker, attacker);
        assertLe(attackerOut, attackDeposit + donation, "attacker profited");
    }

    /// With a 1-wei seed and no attacker deposit, a donation only gifts the locked seed and the virtual shares.
    function testFuzz_donationOnlySeedNeverHurtsVictim(uint256 donation, uint256 victimDeposit) public {
        donation = bound(donation, 0, 1e30);
        victimDeposit = bound(victimDeposit, 1, 1e30);
        PoppieBalanceWrapper w = _createWrapper(address(stock), 1);
        stock.mint(address(w), donation);

        stock.mint(victim, victimDeposit);
        vm.startPrank(victim);
        stock.approve(address(w), victimDeposit);
        try w.deposit(victimDeposit, victim) returns (uint256 s) {
            uint256 out = w.redeem(s, victim, victim);
            assertGe(out + (donation + 1) / 1e6 + 2, victimDeposit);
        } catch (bytes memory err) {
            assertEq(bytes4(err), IPoppieBalanceWrapper.ZeroSharesMinted.selector);
            // Only possible when the deposit is worth less than one share.
            assertLt(victimDeposit * 1e6 * 2, donation + 2);
        }
        vm.stopPrank();
    }
}
