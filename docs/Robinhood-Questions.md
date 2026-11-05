# Questions for Robinhood (Stock Tokens)

*Nov 4, 2026. Poppie plans to accept Robinhood Stock Tokens as collateral in Euler V2 lending markets on Arbitrum once they are deployed there. Our escrow vault would hold the token itself, and we would price each token as equity price × `uiMultiplier()`. We have tested the AAPL token and its registry on a Robinhood Chain fork (findings RH-1 to RH-11 in `docs/EVAL_FINDINGS.md`).*

1. **Arbitrum deployment.** Will Stock Tokens on Arbitrum One be issued natively, or bridged from Robinhood Chain (the `/assets` deployments carry `transporterEnabled` and `replicatorEnabled`)? On every chain, will the multiplier, the pending multiplier, `oraclePaused()` and the blocklist change in the same block, or can they differ for a while? Will Arbitrum tokens use the same registry design and role holders?

2. **Burns from holders.** `adminBurn` (`ADMIN_BURNER_ROLE`) and `burn` (`BURNER_ROLE`, also held by contract `0x1364…9C08`) burn tokens from any holder without an allowance. When are these used (for example sanctions, court orders, redemptions, error correction)? What approvals sit behind those keys? Would a burn ever be used on a lending protocol's escrow contract, and would you give notice first?

3. **Multiplier updates.** The updater is one EOA. `updateMultiplier(uint256)` applies any value at once, and the scheduled version rejects only past times. What controls sit behind that key (MPC, approvals, value checks)? Would you add on-chain bounds or a minimum notice? Is there a feed or webhook of scheduled changes beyond `/corporate-actions`?

4. **SOXX on 2026-11-04.** The SOXX multiplier was set from 1.00045 to 3.0014, effective 14:30 UTC, and set back to 1.00045 effective 17:32 UTC. `/corporate-actions` shows no SOXX split, and `oraclePaused()` was still set at 18:18 UTC. The real SOXX 3:1 split took effect on 2026-11-05: your token moved to 3.0014 effective 14:30 UTC, xStocks at 14:00 and Reality at 08:30. So the 11-04 change looks like the correct split with the wrong date. Is that right, and how did the wrong date get through? Did any holder balances or trades depend on the 3.0 value, and how are such errors handled? CRWD's 4:1 schedule was also sent twice; was that a correction?

5. **Corporate actions outside the multiplier.** The API lists spin-offs, mergers, redemptions, worthless removals, rights distributions and unit splits as "not active at launch". When they become active, how will each pay out: cash, a second token, a burn and re-mint, or a multiplier change? Would payouts reach contract holders such as escrow vaults, and how much notice would holders get?

6. **`oraclePaused()`.** What exactly does the flag cover, and how long does it usually stay set? Do Chainlink's Robinhood feeds stop updating while it is set? Is there a published schedule?

7. **Fees and redemption.** Can any fee be taken through the multiplier? Can the issuer redeem tokens early (for example on a delisting, under the Base Prospectus), and how would holders be paid?

8. **Price feeds.** Chainlink lists 58 Robinhood feeds for 203 tokens. Will every token get a feed, and will the same feeds be published on Arbitrum?

9. **Pauses and blocklist.** One registry pause stops every token. When would you use it, and for how long? Would you ever blocklist a lending protocol's escrow, and would you tell the protocol first?
