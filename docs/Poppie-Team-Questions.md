# Questions for the Poppie team (BSC keeper and market)

*Nov 4, 2026. Prompted by the HONx multiplier halving on xStocks (`docs/HONx-Multiplier-Incident.md`). We want to know whether the same kind of issuer error on an Ondo token would reach the BSC oracle and cause liquidations. On-chain reads below are from the prod oracle `0xAE83F1A1Ea8a4e7CbcaC3551B88E22Baea25f26D` and keeper `0xEA2b72Ed98470Dd7403E2F3da375aD2a77b1c00A`, over the 54 batches from 2026-11-03 21:15 to 11-04 23:45 UTC.*

## What we see on-chain

- The keeper pushes all 36 assets every 30 minutes, 24/5. NFLX is pushed only 14:45–20:45 UTC.
- Pushed prices are total-return: equity × Ondo's multiplier. Keeper price ÷ (Robinhood Chainlink feed ÷ Robinhood multiplier) is about 1.000 for non-payers and above 1 for payers (SPY 1.011, TSM 1.012, ORCL 1.012, MSFT 1.006).
- Ondo tokens have no on-chain multiplier, so the keeper gets it off-chain.
- Live settings: `maxPriceAge` 3600 s, `anchorWindow` 86400 s.
- Breaker and cumulative cap per asset: 3000 bps for 8 ETF and commodity assets, 5000 for 21 assets, 7500 for 7. That is 36 assets: `script/ConfigureProd.s.sol` lists 21, so 15 were added later.
- **Implication:** an exact −50% multiplier error passes 5000 bps whenever equity is flat or up, and passes 7500 outright. The correct price after a reset (about +95%) passes no threshold, so the wrong price would stay live until it goes stale or the admin calls `adminSetPrice`.

## Questions

1. **Price source.** Does the keeper use Chainlink Data Streams' tokenized price, which already includes Ondo's multiplier? Or does it take raw equity and apply a multiplier itself (from Ondo's API, or something else)? Which feed IDs and fields does it use?

2. **Multiplier checks.** Does the keeper check a change in Ondo's multiplier against a known corporate action (dividend calendar, Ondo's `reason` field) before pushing? Does it cap how far the multiplier alone may move a price in one push? What does it do on an unexplained change: alert, skip the asset, or pause it?

3. **Failed entries.** When one asset trips the breaker or cumulative cap, does the keeper pre-simulate and drop it, or does the whole batch revert? A batch revert would leave all 36 assets stale within an hour (EVAL_FINDINGS A1).

4. **Retries.** After a rejected push, does the keeper retry every 30 minutes against the old stored price? If so, a −50% error at 5000 bps passes as soon as equity ticks up. Is there any alerting or back-off on repeated rejections?

5. **Other sanity checks.** Does the keeper compare against a second source (Ondo's own price API, another feed) or against the previous push, beyond the on-chain breaker? Does it skip pushes during Ondo's pause windows (for example the 7:50–8:10 pm ET ex-dividend pause)?

6. **Incident response.** Who holds the oracle admin (`0xd2e0d0Bf42F0f0bd094a587bB1Fa7e03Ff224E6d`): which Safe, and how many signers? How fast can it call `pauseAssets` or `adminSetPrice`? Is a pre-built recovery batch ready? Can the keeper call `pauseAssets` automatically?

7. **Breaker sizing.** Why is the default breaker 50%? A 20–30% breaker would reject a halving on every asset, at the cost of more admin calls on real gaps such as earnings. Has a tighter setting been considered, perhaps only for the overnight session?

8. **Market exposure.** What are the liquidation LTVs per asset on BSC? What share of open debt sits on accounts whose LTV is above half their liquidation LTV, which a halving would make liquidatable? Who liquidates, and how fast?

9. **Ondo history.** Has Ondo's multiplier ever moved unexpectedly or been reverted? If so, did the keeper push it? Ondo's shares-multiplier history API (`/v1/assets/{symbol}/shares-multiplier`) needs a key. Could you run it, or share access, so we can check all 36 assets?

10. **Asset list.** Can you confirm the 15 assets added after `ConfigureProd.s.sol` (AMC, ASML, BMNR, CRWV, EWY, HOOD, IAU, IONQ, NBIS, OKLO, PLTR, SLV, SPCX, TLT, USO) and their intended thresholds? Is there a production config script we should be tracking?

11. **Keeper code.** Can we review the keeper repository, or at least its pricing and push logic? The Arbitrum plan reuses this keeper with extra multiplier rules (xStocks, Robinhood).
