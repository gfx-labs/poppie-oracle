# Questions for the Poppie team (BSC keeper and market)

*Nov 4, 2026. Prompted by the HONx multiplier halving on xStocks (`docs/issuerResearch/HONx-Multiplier-Incident.md`). We want to know whether the same kind of issuer error on an Ondo token would reach the BSC oracle and cause liquidations. On-chain reads below are from the prod oracle `0xAE83F1A1Ea8a4e7CbcaC3551B88E22Baea25f26D` and keeper `0xEA2b72Ed98470Dd7403E2F3da375aD2a77b1c00A`, over the 54 batches from 2026-11-03 21:15 to 11-04 23:45 UTC. Keeper behaviour below is read from the BSC keeper's source code.*

## What we see on-chain

- The keeper pushes all 36 assets every 30 minutes, 24/5. NFLX is pushed only 14:45–20:45 UTC.
- Pushed prices are total-return: equity × Ondo's multiplier. Keeper price ÷ (Robinhood Chainlink feed ÷ Robinhood multiplier) is about 1.000 for non-payers and above 1 for payers (SPY 1.011, TSM 1.012, ORCL 1.012, MSFT 1.006).
- Live settings: `maxPriceAge` 3600 s, `anchorWindow` 86400 s.
- Breaker and cumulative cap per asset: 3000 bps for 8 ETF and commodity assets, 5000 for 21 assets, 7500 for 7. That is 36 assets: `script/ConfigureProd.s.sol` lists 21, so 15 pushed assets were added later (16 counting STRC, which is configured but not pushed).
- **Implication:** an exact −50% multiplier error passes 5000 bps whenever equity is flat or up, and passes 7500 outright. The correct price after a reset (about +95%) passes no threshold, so the wrong price would stay live until it goes stale or the admin calls `adminSetPrice`.

## What the keeper code does

**Schedule.** Pushes run at :15 and :45 past each hour; a separate read-only monitor runs at :20 and :50. Only one push runs at a time.

**Price.** For each asset:
- The keeper reads Chainlink Data Streams' `midPrice`, which is the plain stock price, not a tokenized price.
- Each asset has up to three feeds: regular hours, extended hours and overnight. The keeper takes the freshest feed that reports an open market and is under 10 minutes old. If none qualifies, the asset is skipped and its on-chain price goes stale.

**Multiplier.**
- **Primary:** Ondo's GM API. The multiplier is the token price ÷ the stock price, cached for 30 s.
- **Fallback:** if the API fails, the keeper reads `getSValue` from Ondo's on-chain SyntheticSharesOracle (`0xF4Fd8a1B412633e10527454137A29Db7Aa35F15e`).
- The two sources are never compared with each other.
- The keeper has no corporate-action check and no limit on how far the multiplier can move.

**Guards.**
- **Before submitting:** the keeper simulates the breaker and cumulative-cap checks off-chain and drops any asset that would fail. A dropped asset is logged as a warning, which feeds a dashboard metric but no alert.
- **If the batch still reverts:** the keeper reads the failing asset from the revert data, removes it, and retries once.
- **Halt latch:** three failed runs in a row trip it. Pushes then stop until a person clears it.

**Ondo halt gate.**
- Before pricing, the keeper reads Ondo's asset status API. Any asset with an active `ASSET_PAUSED` window is **paused on-chain by the keeper** (`pauseAssets`), which wipes its stored price.
- `ASSET_LIMITED` is ignored.
- If the status API fails, the gate is skipped and pricing continues as normal.
- A paused asset is pushed again once the admin re-seeds it with `adminSetPrice`. The next valid push then unpauses it.

**Alpha Vantage check.**
- **When it runs:** after the guards, on the assets about to be pushed.
- **What it compares:** the final price, after Ondo's multiplier, against Alpha Vantage's latest stock quote (`REALTIME_BULK_QUOTES`, up to 100 symbols per call).
- **Threshold:** 15%, the same for every asset and session.
- **Coverage:** Alpha Vantage covers 04:00–20:00 ET, so overnight it likely compares against the last extended-hours trade.
- **On a deviation:** it logs an ERROR. Any ERROR fires the keeper's general application-error alert. **It never blocks a push.**
- **Missing data:** a missing symbol or an Alpha Vantage outage is skipped with at most a warning.
- **Other sources:** code for Polygon as a second source exists, but production does not configure it.

**Monitor.** Every 30 minutes, the monitor raises an ERROR when:
- the next price would be rejected by the breaker or cumulative cap;
- a price is stale while a session is live and the asset is not paused;
- the keeper's balance is low;
- the halt latch is tripped;
- security-relevant oracle events have occurred.

It also warns at 70% of the breaker or cap.

**Assets.** The code lists 37 assets: the 36 above plus STRC, which is pushed during regular hours only.

## Answered by the code

- **Price source (was Q1):** raw stock price from Data Streams × Ondo's multiplier from Ondo's API, with the on-chain SyntheticSharesOracle as fallback.
- **Multiplier checks (was Q2):** none.
- **Failed entries (was Q3):** dropped by the off-chain guard check, plus one retry without the reverting asset. A single bad asset does not stale the whole batch.
- **Second source (was Q5):** Alpha Vantage, alert-only, comparing the final price after the multiplier.
- **Keeper pause (part of Q6):** yes, the keeper calls `pauseAssets` automatically on Ondo halts.
- **Keeper code (was Q11):** reviewed.

## Open questions

1. **Retries.** A dropped asset is retried every 30 minutes against the same stored price. So a −50% error at 5000 bps passes as soon as equity ticks up. The monitor raises an error while the next price would be rejected. Is that what the team watches for, and has it fired on a real gap (earnings) or an error?

2. **Alpha Vantage check.**
   - **Plan:** which Alpha Vantage plan is used, real-time or 15-minute delayed?
   - **Does it run at all?** The code reads a `price` field. Alpha Vantage's sample response for `REALTIME_BULK_QUOTES` has no `price` field, only `close`, `extended_hours_quote` and `timestamp`. If the live response matches the sample, every quote is dropped without a log line, and the check never compares anything. Do the logs show any Alpha Vantage comparison, or any "deviation" error?
   - **History:** how often has the 15% alert fired since launch? Were any of those alerts false (overnight, splits, a stale quote), and was any a real error?
   - **Coverage:** do all 37 assets resolve on Alpha Vantage, including SPCX, STRC and the ETFs?
   - **Next step:** has the team planned to make the check blocking, as the design comment suggests ("observe signal quality before deciding to enforce")?

3. **Ondo pause windows.** Ondo pauses for 20 minutes each weekday (00:52–01:12 UTC) for the daily multiplier update. Is the :15/:45 schedule chosen to miss it? If a push did land inside the window, the halt gate would pause the asset and wipe its price, and the admin would have to re-seed it. Is that what caused the July batch that re-seeded 32 paused assets?

4. **Incident response.** Who holds the oracle admin (`0xd2e0d0Bf42F0f0bd094a587bB1Fa7e03Ff224E6d`): which Safe, and how many signers? How fast can it call `pauseAssets` or `adminSetPrice`? Is a pre-built recovery batch kept ready?

5. **Breaker sizing.** Why is the default breaker 50%? A 20–30% breaker would reject a halving on every asset, at the cost of more admin calls on real gaps such as earnings. Has a tighter setting been considered, perhaps only for the overnight session?

6. **Market exposure.** What are the liquidation LTVs per asset on BSC? What share of open debt sits on accounts whose LTV is above half their liquidation LTV, which a halving would make liquidatable? Who liquidates, and how fast?

7. **Ondo history.** Has Ondo's multiplier ever moved unexpectedly or been reverted? If so, did the keeper push it? Ondo's shares-multiplier history API (`/v1/assets/{symbol}/shares-multiplier`) needs a key. Could you run it, or share access, so we can check all 37 assets?

8. **Asset list.** Can you confirm the 16 assets added after `ConfigureProd.s.sol` (AMC, ASML, BMNR, CRWV, EWY, HOOD, IAU, IONQ, NBIS, OKLO, PLTR, SLV, SPCX, STRC, TLT, USO) and their intended thresholds? STRC is in the keeper but we saw no pushes for it. Is there a production config script we should be tracking?

9. **Integration tests.** At `3e5092e`, `go test ./test/integration` fails in all four tests. The suite deploys an older oracle (`int256` prices, a 7-field struct), while the keeper decodes the deployed packed struct (9 fields, of which it reads 8, so per-asset `maxPriceAge` overrides are never seen), and it drives Pyth while production uses Data Streams. Is there another end-to-end test the team relies on, or has this suite been failing since the packed-struct change?

10. **Chainlink.** Which Data Streams plan does Poppie have, and can it cover the xStocks names on Arbitrum? Chainlink's Arbitrum catalog lists Data Streams for 71 of them. Is there a contact at Chainlink for adding feeds, and for pricing 100–500 feeds?

11. **Batch retry.** In the BSC keeper, a batch that reverts on the oracle's breaker or cumulative cap is classified as `circuit_breaker`, but the retry without the failing asset only runs for `tx_revert` (`push/run.go`), so the whole push fails instead. Has a run ever failed this way in production? The off-chain guard check normally prevents it, so it may never have happened (`docs/evaluation/Keeper.md`, KEEP-22).
