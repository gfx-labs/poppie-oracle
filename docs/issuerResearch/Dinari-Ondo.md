# Dinari and Ondo on Arbitrum

*Read on-chain 2026-11-02. Design docs cite these findings by ID (DN-1 to DN-5, ON-1 to ON-3). Verdict: Dinari blocked as is (`recover`); Ondo not deployed on Arbitrum.*

## Dinari

Read on-chain on 2026-11-02 from Dinari's production `DShareFactory` `0xB4Ca72eA4d072C779254269FD56093D3ADf603b8` (address from Dinari's `sbt-contracts` release files). Not yet fork-tested.

- **Coverage:** 251 dShares, each with a wrapped dShare; 238 have supply. Largest by units: USFR 66.5k, ASST 22.1k, STRC 10.1k, MSTR 7.7k, MARA 5.1k, NVDA 4.5k, TSLA 1.6k.
- **Activity:** real but small and concentrated. NVDA had about 3,300 transfers in five weeks, but three EOAs hold about 90% of supply (likely Dinari or partner accounts). No Uniswap v3 USDC pool for NVDA.
- **Wrappers are almost unused:** 11 of 251 have any supply (NVDA 0.044 wrapped shares).

**How the wrapped dShare differs from xStocks' wrapper** (source: `WrappedDShare.sol` in `dinaricrypto/sbt-contracts`):

| | xStocks V2 wrapper | Dinari wrapped dShare |
| --- | --- | --- |
| Exchange rate | Supply × multiplier; donations can't move it | Wrapper's dShare balance (Solady `ERC4626`); **donations and reinvested dividends move it**. NVDA: 1 wrapped share = 15.08 dShares; USFR: 5 shares hold 727 dShares |
| Splits | Multiplier | `balancePerShare` rebase (NVDA shows its 10:1 split) |
| Dividends | Reinvested into the multiplier | Dinari deposits dShares into the wrapper |
| Issuer can remove backing | No | **Yes: `recover(account, amount)` sends the wrapper's dShares anywhere** (present in the deployed implementation) |
| Restrictions | Sanctions list | Dinari transfer restrictor (blacklist) on dShare and wrapper |
| Upgrades | 2-of-3 Safe | One beacon for all dShares and one for all wrappers, owned by **EOA** `0x06B0…60a3`, which also owns the transfer restrictor |

**Status: not listable as is.**

- The admin's `recover` lets Dinari remove the collateral backing, so every escrowed wrapped dShare depends on that key.
- With so few wrapped shares, the exchange rate is easy to push up with a donation. That only raises collateral value with the donor's own money, but it makes `convertToAssets` a poor keeper input until supply is meaningful.
- Raw dShares are not an option either: they rebase on splits and their dividends are cash.

## Ondo

Ondo GM has static balances and reinvested dividends, so it would fit with no wrapper. Its docs do not list Arbitrum as a supported chain, and its BSC token addresses have no code there (ON-1).

## Findings

| ID | Status | Finding | Evidence |
| --- | --- | --- | --- |
| DN-1 | Info | Production `DShareFactory` `0xB4Ca…03b8` emitted 251 `DShareAdded` events (dShare plus wrapped dShare); 238 have supply, 11 wrappers have any supply | `cast logs`, `cast call` |
| DN-2 | **Blocker as is** | The wrapped dShare has `recover(account, amount)`, letting its admin send the wrapper's dShares anywhere (selector present in deployed implementation `0x9941…5dE1`) | `WrappedDShare.sol`; deployed bytecode |
| DN-3 | Issue | Wrapped dShare `totalAssets` is the wrapper's dShare balance (Solady `ERC4626`), so donations and Dinari's dividend deposits move the rate. NVDA `convertToAssets(1e18)` = 15.08e18; USFR 5 shares back 727 dShares | `cast call` |
| DN-4 | Issue | Upgrade beacons for all dShares (`0x1543…dacb`) and all wrappers (`0xad20…f7c5`), and the transfer restrictor, are owned by EOA `0x06B0…60a3`. The deployed dShare and wrapper don't expose `owner`, `defaultAdmin` or `hasRole`, so the admin of `recover` and `setBalancePerShare` wasn't confirmed | `cast call` |
| DN-5 | Issue | Holdings are concentrated: three EOAs hold ~90% of NVDA, ~98% of MSTR. No Uniswap v3 USDC pool for NVDA | `cast logs`, `cast call` |
| ON-1 | Confirmed | Ondo GM's BSC token addresses (`NVDAon`, `TSLAon`) have no code on Arbitrum, consistent with Ondo's docs | `cast codesize` |
| ON-2 | **Issue (BSC)** | **A Backed-style halving (−50%) of an Ondo multiplier would likely stay live on BSC.** Prod oracle `0xAE83…5f26D`, keeper `0xEA2b…1c00A`, 54 batches 2026-11-03 to 11-04: 36 assets pushed every 30 min (NFLX only 14:45–20:45 UTC). Prices are total-return (equity × Ondo multiplier). `maxPriceAge` 3600 s, `anchorWindow` 86400 s. Breaker and cap per asset: 3000 bps for 8 ETF and commodity assets, 5000 for 21, 7500 for 7. A −50% error passes 5000 bps when equity is flat or up, and 7500 outright; the correct reset (about +95%) passes no threshold, so the wrong price stays until it goes stale or the admin calls `adminSetPrice`. The keeper has no multiplier check (KEEP-3 covers the alert-only Alpha Vantage check); a failing asset is retried every 30 min against the same stored price | On-chain reads; BSC keeper source; `Design.md` \"Keeper\" |
| ON-3 | Info | **Ondo pause window and keeper pausing.** Ondo pauses each weekday 00:52–01:12 UTC for the daily multiplier update. The BSC keeper pauses on-chain (`pauseAssets`, wiping the price) any asset with an active `ASSET_PAUSED`, and the admin must re-seed it. Pushes at :15/:45 miss the window; a July batch re-seeded 32 paused assets (cause unconfirmed). 16 pushed assets were added after `script/ConfigureProd.s.sol` (36 pushed; 37 with STRC, configured but not pushed), so no config script matches production | Ondo status API; BSC keeper source |

## Open questions for the Poppie team (BSC)

1. **Alerts:** has the monitor's \"next price would be rejected\" error fired on a real gap or error?
2. **Alpha Vantage:** which plan; does any comparison or deviation error appear in logs (KEEP-3); how often has the 15% alert fired and was any real; do all 37 assets resolve (SPCX, STRC, ETFs); will the check become blocking?
3. **July re-seed:** was it caused by a push inside the Ondo pause window?
4. **Incident response:** who holds the oracle admin (`0xd2e0…4E6d`): which Safe, how many signers, how fast can it `pauseAssets` or `adminSetPrice`, is a recovery batch ready?
5. **Breaker sizing:** why 50% by default? Would 20–30% (perhaps overnight only) be considered?
6. **Exposure:** liquidation LTVs per asset, share of debt above half the liquidation LTV, who liquidates and how fast.
7. **Ondo history:** has a multiplier ever moved unexpectedly, and did the keeper push it? Ondo's `/v1/assets/{symbol}/shares-multiplier` needs a key; can they run it or share access?
8. **Config:** confirm the 16 later assets (AMC, ASML, BMNR, CRWV, EWY, HOOD, IAU, IONQ, NBIS, OKLO, PLTR, SLV, SPCX, STRC, TLT, USO) and their thresholds; why STRC has no pushes; is there a production config script?
9. **Tests:** is there an end-to-end test that passes (KEEP-2)? **Retry:** has a run failed because the retry skipped a guard revert (KEEP-22)?
10. **Chainlink:** which Data Streams plan, can it cover xStocks on Arbitrum (71 names, KEEP-4), is there a contact for 100–500 feeds?
