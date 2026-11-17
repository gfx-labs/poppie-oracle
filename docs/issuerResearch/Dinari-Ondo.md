# Dinari and Ondo on Arbitrum

*Read on-chain 2026-11-02. Design docs cite these findings by ID (DN-1 to DN-5, ON-1). Verdict: Dinari blocked as is (`recover`); Ondo not deployed on Arbitrum.*

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
