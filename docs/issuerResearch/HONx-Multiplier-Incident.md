# HONx multiplier halving, 2026-06-29

*Read on-chain 2026-11-04 (Etherscan/Blockscout, Arbitrum RPC). Cause not yet confirmed by Backed (`docs/issuerResearch/xStocks-Backed-Questions.md` Q15).*

## What happened

Backed's updater EOA scheduled HONx's multiplier to exactly half its value with about 5 minutes' notice. It then scheduled a reset 8 h 25 min later, again with about 5 minutes' notice. Both chains received identical schedules. While the multiplier was halved, every HONx balance, and every wrapper's `convertToAssets`, showed half the true value.

| Step | Multiplier | Sent (UTC) | Active (UTC) | Notice | Ethereum tx | Arbitrum tx |
| --- | --- | --- | --- | --- | --- | --- |
| Halve | 1.024094713 → 0.512047357 | 06-29 15:24 | **06-29 15:30** | ~5 min | [`0xed3774ed…`](https://etherscan.io/tx/0xed3774ede28e85816b04bbc3a2814e8815949821ab9cb3c512c2213e1bff4d4f) | [`0xa2daeada…`](https://arbiscan.io/tx/0xa2daeadaed0b90e49dd7bbcd21bca1275ce679273a5ffcdf7e4059c227c316cb) |
| Reset | 0.512047357 → 0.999065507 | 06-29 23:50 | **06-29 23:55** | ~4.5 min | [`0x1fcf2ca3…`](https://etherscan.io/tx/0x1fcf2ca3410658b222bba844332abb801398a57c1c7731d9cc34afe26f4d768d) | [`0x7be0a9b3…`](https://arbiscan.io/tx/0x7be0a9b3b9847907422275355411e23744ad2da0127667052bf5756a6ec12cbd) |

- Both transactions call `updateMultiplierValue(new, old, activationTime)` from `0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD`.
- The halved value was live from 15:30 to 23:55 UTC: 8 h 25 min, covering most of the US regular session and all of the extended session.
- The reset value is **2.44% below** the pre-halving value (0.99907 vs 1.02409). Neither step matches a corporate action we know of. Honeywell Aerospace (HONAx) was only listed on 2026-10-28.
- Notice was about 5 minutes, below the 15-minute minimum and the 2-hour norm Backed described. Activation at 15:30 UTC is also outside Backed's documented 00:30 UTC slot, although real activation times vary (XS-6, KEEP-19).

**Correction to earlier notes.** `MultiplierUpdated` is emitted lazily, on the first token interaction after activation. That is why logs show the reset on 2026-07-09 (Ethereum) and 2026-07-26 (Arbitrum). Those are not activation times. The multiplier in effect follows the activation timestamp. XS-13 and XS-14 (`docs/issuerResearch/xStocks.md`) have been corrected.

## Contracts

| | Address |
| --- | --- |
| HONx token (same on both chains) | `0x62a48560861b0b451654bfffdb5be6e47aa8ff1b` ([Etherscan](https://etherscan.io/token/0x62a48560861b0b451654bfffdb5be6e47aa8ff1b), [Arbiscan](https://arbiscan.io/token/0x62a48560861b0b451654bfffdb5be6e47aa8ff1b)) |
| V2 wrapper | `0xd762788960c607109151ef84efccb19c3ad18012` |
| Legacy wrapper | `0xbd1b73b2e89967e83507b500d798998200a53380` |
| Multiplier updater (Backed EOA) | `0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD` |

## Who was exposed

Balances were rebuilt from `Transfer` logs, converted to share units at the multiplier in effect.

| | Ethereum | Arbitrum |
| --- | --- | --- |
| Total supply (shares) | 50,437.6 | 41,261.9 |
| Held by Backed's EOA | 50,413.9 (99.95%) | 41,261.9 (100%) |
| **Outside Backed** | **23.70 shares (0.05%), 7 addresses** | **0** |
| Holders with ≥ 0.01 share | 3 | 0 |
| Transfers while halved | 0 | 0 |
| V2 and legacy wrapper supply | 0 | 0 |

Ethereum holders outside Backed:
- `0x4Cacec388dba5E7a57EEEd9834D204324d723980`: 23.19 shares, about 98% of the outside float (roughly $5k at about $200 a share);
- Uniswap v4 `PoolManager` `0x000000000004444c5dc75cB358380D2e3dE08A90`: 0.31;
- `0x9FA8E170e8b264FA82C5D68e9dA76399D07409F7`: 0.20;
- four dust balances.

No HONx moved on either chain while the multiplier was halved, so no trade, pool swap or redemption settled at the wrong value. The only real-world harm was displayed balances and any off-chain valuation that read `balanceOf`.

## Reality did something similar on the same day

Reality's rHON token on Arbitrum shows a halving on the same day:

- **Steps:** its registry recorded a 2→1 reverse split for HON, effective 2026-06-29 04:00 UTC. It was executed twice, at 04:00 ([tx](https://arbiscan.io/tx/0x420ecbf33e769be52ca185d41b0336c9d0032ef9fe7f7d1df23ff6f9fe84caea)) and at 10:49 ([tx](https://arbiscan.io/tx/0x579f164b6dbf245d056b67b0ef86dd589e31a8e8e7fce79236390cf33421fc29)). That is a cumulative 4→1, and it was never reversed. The 2026-10-17 migration carried it into rHON's multiplier as 0.25.
- **Comparison:** xStocks' HONx ended the day near its old value (now 1.0012), so the two issuers disagree by 4×. Neither matches a Honeywell event we can confirm.
- **Exposure:** rHON's supply is 0.001 tokens, so no one is exposed.
- **What this suggests:** something in the Honeywell data feed that day produced a 2:1 factor at both issuers. We have not confirmed that. See RE-4 (`docs/issuerResearch/Reality.md`) and `docs/issuerResearch/Reality-Questions.md` Q7.

## What it would have done to Poppie

- **Router:** the wrapper share is priced directly, so the collateral value does not move on-chain when the multiplier changes. Only a keeper push can move it.
- **Keeper that follows the multiplier:** it pushes −50%. That passes a 5000 bps breaker and would have made HONx borrowers liquidatable during market hours. The zero-contract design's proposed blue-chip breaker (20%) would reject it, and the name would go stale for about 8.5 hours instead.
- **Keeper rule** (apply only multiplier changes that match a known corporate action): it rejects both steps. It then has to decide whether to accept the −2.44% net change, which it cannot verify without Backed.
- **Governance:** the 5-minute notice is too short for any Safe action. Only automated keeper rules help.

## Would the BSC deployment have pushed it?

HONx isn't listed on BSC. The question is what would happen if Ondo's multiplier did the same on a BSC collateral. Prices were read on-chain on 2026-11-04 from the prod oracle `0xAE83F1A1Ea8a4e7CbcaC3551B88E22Baea25f26D` (keeper `0xEA2b72Ed98470Dd7403E2F3da375aD2a77b1c00A`). The free RPC only served the last 54 batches (2026-11-03 21:15 to 11-04 23:45 UTC). Keeper behaviour is from the BSC keeper's source code.

**The keeper follows the issuer multiplier.**
- Price = Chainlink Data Streams stock price × Ondo's multiplier.
- The multiplier comes from Ondo's GM API (token price ÷ stock price). If the API fails, it comes from Ondo's on-chain SyntheticSharesOracle (`getSValue`).
- On-chain, the pushed prices match: keeper price ÷ equity is
  - ≈ 1.000 for non-payers (AMD, AMZN, COIN, CRCL, TSLA, RKLB, SNDK);
  - above 1 for dividend payers: SPY 1.011, ORCL 1.012, TSM 1.012, BABA 1.009, MSFT 1.006, QQQ 1.005.
  - The equity reference here is Robinhood's Chainlink feed ÷ Robinhood's multiplier, at each push time.

**What the keeper filters.**
- **Sessions:** it pushes every 30 minutes, 24/5, whenever a Data Streams feed is fresh and the market is open. NFLX has only a regular-hours feed, so it is pushed only 14:45–20:45 UTC.
- **Multiplier:** nothing. There is no corporate-action check and no limit on how far the multiplier can move a price.
- **Guards:** it simulates the breaker and cumulative cap off-chain and drops any asset that would fail, so one bad asset does not revert the batch. A dropped asset is retried every 30 minutes against the same stored price.
- **Ondo halts:** if Ondo's status API shows the asset as `ASSET_PAUSED`, the keeper pauses it on-chain. An erroneous multiplier with no Ondo pause is not caught here.
- **Alpha Vantage check:**
  - It compares the final price, after the multiplier, with Alpha Vantage's stock quote, and logs an ERROR above 15%, which alerts the team.
  - **A halving would alert** (about 50% deviation), but the check never blocks a push.
  - The check sees a legitimate dividend multiplier as a deviation of a few percent, well under 15%.

**Live settings.**
- `maxPriceAge` 3600 s; `anchorWindow` 86400 s.
- Breaker and cumulative cap per asset, matching `ConfigureProd.s.sol` plus 15 later additions.

| Breaker | Assets | Halving (−50%) | Reset (≈ +95%) |
| --- | --- | --- | --- |
| 3000 | SPY, QQQ, EWY, IAU, SLV, SPCX, TLT, USO (8) | Dropped by the keeper; the monitor raises an error; the price goes stale after 1 h | n/a |
| 5000 | AAPL, AMD, AMZN, BABA, COIN, CRCL, GOOGL, INTC, META, MSFT, MU, NFLX, NVDA, ORCL, SNDK, TSLA, TSM, AMC, ASML, HOOD, PLTR (21) | Passes if equity is flat or up since the last accepted push. Otherwise dropped and retried every 30 min against the same reference, so over 8 h it very likely passes | Dropped |
| 7500 | MSTR, RKLB, BMNR, CRWV, IONQ, NBIS, OKLO (7) | Passes | Dropped |

**Outcome for 28 of 36 assets:**
- The halved price would likely go live. HONx-style accounts with LTV above half the liquidation LTV become liquidatable.
- The team is alerted within one push cycle by the Alpha Vantage check. Until the halved price passes, the monitor's rejected-price error also fires. Nothing stops the push automatically, so the exposure lasts until someone acts.
- The correct post-reset price exceeds every breaker. The keeper drops it, and the halved price stays until it goes stale (1 h) or the Safe calls `adminSetPrice`.
- In v2 the keeper's multiplier gate would skip the halved price: the change matches no corporate action. Its stock-price gate compares stock to stock, so it would not see this error (see `docs/zeroContracts/Design.md`, "Price sources and cross-check").
- The v2 keeper prototype replays this on an Arbitrum fork (`TestRogueHalving`, KEEP-11 in `docs/evaluation/Keeper.md`). The halving is skipped and paged on every run, because Backed's API reports the same value and only the corporate-action calendar flags it. The real reset landed 2.44% below the earlier value, so the keeper would keep skipping HONx until someone adds a manual approval to the calendar.
