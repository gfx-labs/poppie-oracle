# Questions for Backed (xStocks on Arbitrum)

*Nov 2, 2026. Poppie plans to accept xStocks as collateral in Euler V2 lending markets on Arbitrum, holding the V2 wrapper (`wrapperAddressV2`) and pricing each wrapper share as equity price × `convertToAssets(1e18)`. We have tested the token and wrapper contracts on an Arbitrum fork.*

1. **Liquidity for liquidations.** Nearly all Arbitrum supply of the major names sits in `0x5F7A…a2aD`, the V2 wrappers hold nothing, and we found no DEX pools. Will there be on-chain exit liquidity on Arbitrum (pools, market makers, xChange), and for which names? Could a liquidator without a Backed account sell seized collateral, or could Backed or a partner act as a backstop buyer?

   > **Backed (Nov 3):** xChange is available on Arbitrum. While we have solvers that can quote there, a better approach would be integrating CoW or some other protocols where they are already solving on. We can't do it with Backed btw.

2. **Corporate actions outside the multiplier.** Splits, reverse splits and reinvested dividends flow through the multiplier, which the wrapper follows. How are mergers, spin-offs, delistings and token migrations handled: could the token or wrapper ever receive cash or a second token, and how much notice do holders get?

   > **Backed (Nov 3):** Splits and dividends are internalised via multiplier changes. On mergers etc it happens on a case by case basis and we always make sure users are made whole. Users will know well in advance, depending on how long it takes us to know firsthand.

3. **Multiplier changes.** The multiplier updater is a single EOA that can set any value instantly. What controls sit behind that key, how far ahead are updates scheduled, and can we get advance notice (webhook or schedule) on Arbitrum, including the exact activation time?

   > **Backed (Nov 3):** We have verified data sources that are then modifying the multiplier.

## Follow-ups (Nov 3)

*Since your reply, we've looked at on-chain activity. Nearly all xStocks trades on Arbitrum, including 58 of 59 CoW trades, are fills from `0x5F7A…a2aD` through your `AtomicSwap` contract (`0x6F86…8852`) to allowlisted takers. The questions below build on that.*

4. **"We can't do it with Backed."** What did this rule out: a direct integration with Backed, Backed building the CoW integration, or Backed acting as a backstop buyer?

5. **Atomic liquidations.** Could Backed allowlist a Poppie liquidator contract on `AtomicSwap` and serve it signed sell quotes by API? That would let a liquidation seize, unwrap, sell and repay in one transaction.

6. **Sell-side depth and hours.** The largest sale through `AtomicSwap` so far is about $38k, and we see no weekend fills. What sell size per name will you quote, and do you quote at weekends or only on weekdays?

7. **Wrapper holders in corporate actions.** When users are made whole in a merger, spin-off or delisting, does that include V2 wrapper holders, including contracts such as lending escrows? Could cash or a second token arrive at the wrapper, and if so, how would it reach wrapper holders?

8. **Multiplier updates.** The contract lets the updater key set any value with any activation time. Would you add on-chain bounds or a minimum schedule delay? Is there a feed or calendar of scheduled multiplier changes we can subscribe to?
