# Questions for Backed (xStocks on Arbitrum)

**Status (Nov 4, 2026):** questions 1–8 answered. Questions 9–18 not yet sent. Priority: 12 and 17 (what wrapper holders get in a merger), 15 (the HONx halving) and 9 (Oku onboarding, decision D9).

*Nov 2, 2026. Poppie plans to accept xStocks as collateral in Euler V2 lending markets on Arbitrum, holding the V2 wrapper (`wrapperAddressV2`) and pricing each wrapper share as equity price × `convertToAssets(1e18)`. We have tested the token and wrapper contracts on an Arbitrum fork.*

1. **Liquidity for liquidations.** Nearly all Arbitrum supply of the major names sits in `0x5F7A…a2aD`, the V2 wrappers hold nothing, and we found no DEX pools. Will there be on-chain exit liquidity on Arbitrum (pools, market makers, xChange), and for which names? Could a liquidator without a Backed account sell seized collateral, or could Backed or a partner act as a backstop buyer?

   > **Backed (Nov 3):** xChange is available on Arbitrum. While we have solvers that can quote there, a better approach would be integrating CoW or some other protocols where they are already solving on. We can't do it with Backed btw.

2. **Corporate actions outside the multiplier.** Splits, reverse splits and reinvested dividends flow through the multiplier, which the wrapper follows. How are mergers, spin-offs, delistings and token migrations handled: could the token or wrapper ever receive cash or a second token, and how much notice do holders get?

   > **Backed (Nov 3):** Splits and dividends are internalised via multiplier changes. On mergers etc it happens on a case by case basis and we always make sure users are made whole. Users will know well in advance, depending on how long it takes us to know firsthand.

3. **Multiplier changes.** The multiplier updater is a single EOA that can set any value instantly. What controls sit behind that key, how far ahead are updates scheduled, and can we get advance notice (webhook or schedule) on Arbitrum, including the exact activation time?

   > **Backed (Nov 3):** We have verified data sources that are then modifying the multiplier.

## Follow-ups (Nov 3)

*Since your reply, we've looked at on-chain activity. Nearly all xStocks trades on Arbitrum, including 58 of 59 CoW trades, are fills from `0x5F7A…a2aD` through your `AtomicSwap` contract (`0x6F86…8852`) to allowlisted takers. The questions below build on that.*

4. **"We can't do it with Backed."** Can you elaborate on what you mean by "We can't do it with Backed"? What did this rule out: a direct integration with Backed, Backed building the CoW integration, or Backed acting as a backstop buyer? It looks like Backed is making up very nearly all of the liquidity behind CoW.

   > **Backed (Nov 4):** Backed cannot liquidate directly. A solver can, via CoW.

5. **Atomic liquidations.** Could Backed potentially allowlist a Poppie liquidator contract on `AtomicSwap` and serve it signed sell quotes by API? That would let a liquidation seize, unwrap, sell and repay in one transaction.

   > **Backed (Nov 4):** Would we need to onboard Oku in that case? Because without having a party that is onboarded, we can't whitelist a contract address.

6. **Sell-side depth and hours.** The largest sale through `AtomicSwap` I found so far is about $38k, and I see no weekend fills. What max sell size per name will you quote, and do you quote at weekends or only on weekdays?

   > **Backed (Nov 4):** $1m on majors during market hours, the number goes down to $10k per tx during the overnight session for names in the longer tail. We don't provide executable quotes during the weekend.

7. **Wrapper holders in corporate actions.** When users are made whole in a merger, spin-off or delisting, does that include V2 wrapper holders, including contracts such as lending escrows? Could cash or a second token arrive at the wrapper, and if so, how would it reach wrapper holders?

   > **Backed (Nov 4):** We would need users to unwrap and we would provide a facility to liquidate either via Atomic RFQ on protocols or eventually other ways.

8. **Multiplier updates.** The contract appears to let the updater key set any value with any activation time. Is there a feed or calendar of scheduled multiplier changes we can subscribe to? Would you consider a minimum delay between scheduling and activation?

   > **Backed (Nov 4):** We have an endpoint that can be polled for pending multipliers (see [docs](https://docs.xstocks.fi/apis/openapi/assets/get_public_assets_multiplier_by_symbol)). The lead time can be as little as 15 minutes (as sometimes our data providers only deliver the corporate action data in the last minute). Normally one can expect it to be updated 2 hours in advance.
   >
   > *Endpoint:* `GET https://api.xstocks.fi/api/v2/public/assets/{symbol}/multiplier?network=Arbitrum` returns `currentMultiplier`, `newMultiplier`, `activationDateTime` and `reason` (`FeeAccrual`, `Dividend`, `Split`, `ReverseSplit`, `Administrative`). Checked 2026-11-04: AAPLx `currentMultiplier` 1.0032690125398187, nothing pending. Values are floats.

## Slippage (team conversation, Nov 4)

> **Team:** There is a big difference in your liquidity between regular hours and after hours. Do you guys have plans to improve that? In regular hours there is a 6–7 bps slippage on a round-trip $1K NVDA trade, whereas in after hours it's more like 40 bps.
>
> **Backed:** That also depends on the protocol and solver to be honest. NVDAx should have 5-10-20bps of slippage during the three market sessions. This is for one leg, not round trip. I would also add that the liquidity on the market for stocks is not excellent by default outside of market hours.
>
> **Team:** When you say 20 bps, are you saying it's 20 bps to do one leg? That would line up with the 40 bps round trip I saw.
>
> **Backed:** We are still lowering down spreads gradually, but during market hours those are still very competitive.

## What the Nov 4 answers settle

- **No backstop.** Backed will not buy seized collateral. Liquidation goes through solvers on CoW, or through `AtomicSwap` directly once an onboarded party is in place.
- **Atomic liquidation is possible, but only behind an onboarded party** (Oku, if it onboards). This is now a Poppie decision (D9), not an open question.
- **Exit size and hours are known:** up to $1M per trade on majors in market hours; $10k per trade on long-tail names overnight; no executable quotes at weekends. Supply caps can be sized from this.
- **Corporate actions:** nothing is paid into the wrapper. Holders must unwrap, so Poppie must wind a name down and close or liquidate every position before the event.
- **Multiplier notice:** a polling API with a `reason` field. Backed says notice is normally about 2 hours and at least 15 minutes, with no on-chain minimum. On-chain we saw less: HONx 6 minutes (2026-02-27) and 4–5 minutes (2026-06-29); see 13 and 15. The keeper must handle this automatically; a Safe cannot act in 15 minutes.
- **Slippage:** about 5, 10 and 20 bps one way across the sessions, which is small next to liquidation discounts.

## Follow-ups (Nov 4)

9. **Onboarding Oku.** What does onboarding involve (entity, KYB, documents, jurisdictions, time)? Once Oku is onboarded, can you allowlist a contract address that Oku controls (a liquidator) as a taker on `AtomicSwap`? Would it get signed sell quotes by API, and with what latency, validity window and rate limits? Are there fees?

10. **Quote size.** Is the $1M figure per transaction, and how often can it be repeated (per hour, per day, per name)? Which names count as majors? What size do you quote for majors in the extended and overnight sessions, and for long-tail names in market hours? Does the size hold in a fast market, such as a 10% gap at the open?

11. **Weekly hours.** When do executable quotes stop on Friday and resume on Sunday or Monday (UTC)? What are the exact overnight-session hours?

12. **Unwrap deadline.** In a merger or delisting (or a spin-off not folded into the multiplier), how much notice will holders get to unwrap, and what is the deadline? What happens to V2 wrapper shares still outstanding after it: are they frozen, redeemable later, or paid out some other way? Will the sale facility be open to a liquidator contract behind an onboarded party? Can you notify integrators such as Poppie directly?

13. **Multiplier schedule.** What does the `Administrative` reason cover, and when is it used? Is the API entry published before, at the same time as, or after the on-chain schedule, and can the two ever disagree? From the `updateMultiplierValue` calldata we see HONx scheduled with 6 minutes' notice on 2026-02-27 and 4–5 minutes on 2026-06-29, and AAPLx with 18 minutes on 2026-05-09. Were those late-data cases, and is 15 minutes a floor you enforce? Is a webhook available instead of polling?

### From on-chain history (Nov 4)

*We went through Backed's token factory and multiplier history on Ethereum and Arbitrum. EAx and the other tokens no longer in the API stay live, unburned and held by Backed. No wrapper has held a token through a merger or delisting. Findings XS-11 to XS-14 in `docs/EVAL_FINDINGS.md`.*

14. **Spin-offs.** After Versant's spin-off from Comcast, CMCSAx's multiplier rose 4.72% on 2026-01-07, and VSNTx was only listed in September. Did you sell the Versant shares and reinvest in CMCSA through the multiplier? Is that the standard treatment for every spin-off? For Solstice, HONx's multiplier rose only 1.10% on 2025-10-30. What did that step cover, and how were HONx holders credited for the Solstice shares? Will Honeywell Aerospace (HONAx) be handled the same way?

15. **HONx on 2026-06-29.** The multiplier was scheduled from 1.02409 to 0.51205 (exactly half) at 15:24 UTC, active 15:30, and reset to 0.99907 at 23:50, active 23:55, on both chains, each with about 5 minutes' notice (`docs/HONx-Multiplier-Incident.md`). What happened? Another issuer (Reality) applied a 2→1 HON reverse split twice the same day, so was there a shared data-provider error? Why is the reset 2.44% below the pre-halving value? Were any holders or redemptions affected? What stops this recurring, and why was the notice under your 15-minute minimum?

16. **Cross-chain sync.** Are schedules always sent to every chain with the same activation time, as we saw for HONx and CMCSAx? Which chain is authoritative for redemptions? Does the multiplier API with `network=Arbitrum` always match the Arbitrum contract?

17. **Kenvue (KVUEx).** KVUEx is redemption-only and trading-halted in the API, and KMBx was listed the same day. When Kimberly-Clark's acquisition closes, what will KVUEx holders receive (KMBx, USDC, or both), on which chains, and by what mechanism (a conversion, an airdrop, a redemption window)? What happens to KVUEx tokens and wrapper shares not redeemed by the deadline? Will Qorvo (QRVOx into SWKSx) and Warner Bros. Discovery (WBDx) follow the same process?

18. **Retired tokens.** When a token is dropped (for example EAx) or re-deployed (TEFx, ACS.ESx, HNR1x), the old contract stays live and unpaused. Is the old token still redeemable? Would it ever be paused or burned, and would integrators be told?
