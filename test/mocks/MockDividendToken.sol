// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Dividend-paying token (issuer mechanism `distributing`, e.g. Reality, Dinari): balances never change;
/// the issuer pays dividends to holders in a separate payout token (a stablecoin). Wrapped, so the dividends land
/// on the wrapper and are swept to the reserve.
contract MockDividendToken is MockERC20 {
    /// @notice The token dividends are paid in (mintable mock, e.g. mock USDC).
    MockERC20 public immutable payoutToken;

    event DividendPaid(address indexed holder, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, MockERC20 payoutToken_)
        MockERC20(name_, symbol_, decimals_)
    {
        payoutToken = payoutToken_;
    }

    /// @notice Pay each holder `balanceOf(holder) * perToken / 10**decimals()` payout-token units, i.e. `perToken`
    /// is the payout (in raw payout units) per whole token held.
    function payDividend(address[] calldata holders, uint256 perToken) external {
        for (uint256 i; i < holders.length; ++i) {
            uint256 amount = balanceOf(holders[i]) * perToken / 10 ** decimals();
            if (amount != 0) {
                payoutToken.mint(holders[i], amount);
                emit DividendPaid(holders[i], amount);
            }
        }
    }
}
