// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {PoppieWrapperFactory} from "../../src/wrapper/PoppieWrapperFactory.sol";

import {WrapperFixture} from "../harness/WrapperFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebasingToken} from "../mocks/MockRebasingToken.sol";

/// @notice Random driver for a rebasing-token wrapper: deposits, mints, withdrawals, redemptions, positive and
/// negative rebases, donations, dividends and sweeps (including attempts on the underlying). Reverting calls
/// are swallowed; the invariants then check what must hold after any sequence.
contract WrapperHandler is Test {
    PoppieBalanceWrapper internal immutable w;
    PoppieWrapperFactory internal immutable wf;
    MockRebasingToken internal immutable token;
    MockERC20 internal immutable usdc;
    address internal immutable reserve;

    address[] internal users;

    /// @dev Shares the handler expects, changed only by deposit, mint, withdraw and redeem.
    uint256 public expectedSupply;
    /// @dev Set if a sweep ever lowered the underlying balance or a sweep of the underlying ever succeeded.
    bool public sweepMovedUnderlying;
    /// @dev Set if a sweep ever paid anyone other than the factory's recipient.
    bool public sweepPaidElsewhere;
    uint256 public sweptUsdc;
    uint256 public rebases;

    constructor(
        PoppieBalanceWrapper w_,
        PoppieWrapperFactory wf_,
        MockRebasingToken token_,
        MockERC20 usdc_,
        address reserve_
    ) {
        w = w_;
        wf = wf_;
        token = token_;
        usdc = usdc_;
        reserve = reserve_;
        expectedSupply = w_.totalSupply();
        for (uint256 i; i < 4; ++i) {
            users.push(address(uint160(0xA11CE + i)));
        }
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function userAt(uint256 i) external view returns (address) {
        return users[i];
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function deposit(uint256 who, uint256 amount) external {
        address u = _user(who);
        amount = bound(amount, 1, 1e27);
        token.mint(u, amount);
        vm.startPrank(u);
        token.approve(address(w), amount);
        try w.deposit(amount, u) returns (uint256 shares) {
            expectedSupply += shares;
        } catch {}
        vm.stopPrank();
    }

    function mint(uint256 who, uint256 shares) external {
        address u = _user(who);
        shares = bound(shares, 1, 1e33);
        uint256 need = w.previewMint(shares);
        token.mint(u, need + 1);
        vm.startPrank(u);
        token.approve(address(w), need);
        uint256 before = w.balanceOf(u);
        try w.mint(shares, u) {
            expectedSupply += w.balanceOf(u) - before;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 who, uint256 assets) external {
        address u = _user(who);
        assets = bound(assets, 0, w.maxWithdraw(u));
        vm.prank(u);
        try w.withdraw(assets, u, u) returns (uint256 burned) {
            expectedSupply -= burned;
        } catch {}
    }

    function redeem(uint256 who, uint256 shares) external {
        address u = _user(who);
        shares = bound(shares, 0, w.balanceOf(u));
        vm.prank(u);
        try w.redeem(shares, u, u) {
            expectedSupply -= shares;
        } catch {}
    }

    function rebase(uint256 mult) external {
        token.rebase(bound(mult, 0.25e18, 4e18));
        rebases++;
    }

    function donate(uint256 amount) external {
        token.mint(address(w), bound(amount, 0, 1e24));
    }

    function payDividendAndSweep(uint256 amount, uint256 callerSeed) external {
        amount = bound(amount, 0, 1e12);
        usdc.mint(address(w), amount);
        _sweep(address(usdc), address(uint160(callerSeed)));
    }

    function sweepUnderlying(uint256 callerSeed) external {
        _sweep(address(token), address(uint160(callerSeed)));
    }

    function sweepShares(uint256 who, uint256 shares) external {
        address u = _user(who);
        shares = bound(shares, 0, w.balanceOf(u));
        vm.prank(u);
        w.transfer(address(w), shares);
        _sweep(address(w), u);
    }

    function _sweep(address t, address caller) internal {
        uint256 underlyingBefore = token.balanceOf(address(w));
        uint256 recipientBefore = t == address(token) ? 0 : MockERC20(t).balanceOf(wf.dividendRecipient());
        uint256 held = t == address(token) ? 0 : MockERC20(t).balanceOf(address(w));
        vm.prank(caller);
        try w.sweep(t) returns (uint256 amount) {
            if (t == address(token)) sweepMovedUnderlying = true;
            if (MockERC20(t).balanceOf(wf.dividendRecipient()) != recipientBefore + amount || amount != held) {
                sweepPaidElsewhere = true;
            }
            if (t == address(usdc)) sweptUsdc += amount;
        } catch {}
        if (token.balanceOf(address(w)) < underlyingBefore) sweepMovedUnderlying = true;
    }
}

contract WrapperInvariantsTest is WrapperFixture {
    WrapperHandler internal handler;
    PoppieBalanceWrapper internal w;
    uint256 internal seedShares;

    function setUp() public override {
        super.setUp();
        w = _createWrapper(address(rebasing), 1);
        seedShares = w.balanceOf(address(wrapperFactory));
        handler = new WrapperHandler(w, wrapperFactory, rebasing, usdc, reserve);
        targetContract(address(handler));
    }

    /// Shares change only on deposit, mint, withdraw and redeem; rebases, donations and sweeps never touch them.
    function invariant_shareCountOnlyMovesOnUserActions() public view {
        assertEq(w.totalSupply(), handler.expectedSupply());
    }

    /// Seed shares are locked permanently.
    function invariant_seedSharesLocked() public view {
        assertEq(w.balanceOf(address(wrapperFactory)), seedShares);
    }

    /// Every share is accounted for by users, the locked seed, or the reserve (swept shares).
    function invariant_sharesAccounted() public view {
        uint256 sum = w.balanceOf(address(wrapperFactory)) + w.balanceOf(reserve) + w.balanceOf(address(w));
        for (uint256 i; i < handler.usersLength(); ++i) {
            sum += w.balanceOf(handler.userAt(i));
        }
        assertEq(sum, w.totalSupply());
    }

    /// The wrapper never owes more than it holds.
    function invariant_solvent() public view {
        assertLe(w.convertToAssets(w.totalSupply()), w.totalAssets());
    }

    /// `sweep` never moves the underlying and pays only the factory's recipient.
    function invariant_sweepSafety() public view {
        assertFalse(handler.sweepMovedUnderlying());
        assertFalse(handler.sweepPaidElsewhere());
        assertEq(usdc.balanceOf(reserve), handler.sweptUsdc());
        assertEq(usdc.balanceOf(address(w)), 0);
    }
}
