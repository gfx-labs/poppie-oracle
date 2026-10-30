// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoppieBalanceWrapper} from "../../src/wrapper/PoppieBalanceWrapper.sol";
import {PoppieWrapperFactory} from "../../src/wrapper/PoppieWrapperFactory.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebasingToken} from "../mocks/MockRebasingToken.sol";
import {MockMultiplierToken} from "../mocks/MockMultiplierToken.sol";
import {MockDividendToken} from "../mocks/MockDividendToken.sol";
import {PoppieTestBase} from "./PoppieTestBase.sol";

/// @notice Wrapper factory on top of the local Euler stack, plus one mock token per issuer mechanism:
/// `rebasing` (balance-changing), `multiplierToken` (multiplier, not wrapped) and `dividend` (distributing, paying
/// in `usdc`). Later tickets (escrow hook, router governor, steward, scripts) can reuse it.
abstract contract WrapperFixture is PoppieTestBase {
    /// @dev Stands in for the timelock (`DEFAULT_ADMIN_ROLE`, i.e. MS_ADMIN).
    address internal timelock;
    /// @dev The reserve Safe.
    address internal reserve;
    /// @dev The KMS deployer key that pays seeds.
    address internal deployer;

    PoppieWrapperFactory internal wrapperFactory;

    MockRebasingToken internal rebasing;
    MockMultiplierToken internal multiplierToken;
    MockDividendToken internal dividend;

    function setUp() public virtual override {
        super.setUp();
        timelock = makeAddr("timelock");
        reserve = makeAddr("reserve");
        deployer = makeAddr("deployer");

        wrapperFactory = new PoppieWrapperFactory(timelock, reserve);

        rebasing = new MockRebasingToken("Mock xStock", "mXS", 18);
        multiplierToken = new MockMultiplierToken("Mock Multiplier", "mMUL", 18);
        dividend = new MockDividendToken("Mock Dividend", "mDIV", 18, usdc);
    }

    /// @notice Create the wrapper for `token` as `deployer`, minting the seed to the deployer first.
    /// `token` must expose `mint(address,uint256)` (every mock here does).
    function _createWrapper(address token, uint256 seed) internal returns (PoppieBalanceWrapper w) {
        MockERC20(token).mint(deployer, seed);
        vm.startPrank(deployer);
        IERC20(token).approve(address(wrapperFactory), seed);
        w = PoppieBalanceWrapper(wrapperFactory.createWrapper(token, seed));
        vm.stopPrank();
    }

    /// @notice Mint `amount` of `token` to `user` and deposit it into `w`.
    function _deposit(PoppieBalanceWrapper w, address user, uint256 amount) internal returns (uint256 shares) {
        MockERC20(w.asset()).mint(user, amount);
        vm.startPrank(user);
        IERC20(w.asset()).approve(address(w), amount);
        shares = w.deposit(amount, user);
        vm.stopPrank();
    }
}
