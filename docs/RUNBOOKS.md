# Runbooks (v2)

Operational procedures for the roles in `docs/CONTRACT_SPEC.md` §4. Every on-chain step here is executed by a human (Safe signers) or by the KMS services; agents never broadcast (see `AGENTS.md`). Safe batches are generated with `script/BuildListingBatch.s.sol` or written by hand in the Safe Transaction Builder, and checked with `script/ConfigCheck.s.sol` before and after.

## 1. Corporate action (split, reverse split, in-kind dividend)

Goal: never let collateral be valued on a stale per-token price after the token's balance or multiplier changed.

1. **Before** (earnings calendar / issuer notice): `K_TIGHTEN` lowers the name's borrow LTV and supply cap (`lowerBorrowLTV`, `lowerCaps`). Batch all names with actions in the window.
2. **At the action:** `K_PRICE` pushes the **post-action** price in the same block as, or immediately after, the balance change.
   - A move beyond the class bound becomes *Unconfirmed*: the bid is `min(P, L × (1 − h))`, which is safe for a split (collateral is not overvalued), and liquidations wait for confirmation.
   - `K_CONFIRM` confirms once its independent checks agree (sources, the issuer's announcement, the new multiplier).
3. **If the keeper cannot push at the action:** `K_PRICE` pauses the asset (*Closed*). **Residual risk:** while Closed the bid is `L × (1 − h)` on the old price, and a split doubles the escrow's balance, overvaluing collateral by `2 × (1 − h)` (test `test_finding_splitWhileClosedOnStalePriceOvervaluesBid`). Mitigate with step 1 and `K_GUARD.pauseBorrows` on the affected hubs until the price is pushed.
4. **Unpause** (`MS_OPS`, `unpauseAssets`) only once **both** the token's balance or multiplier **and** the pushed price reflect the action. Then end any borrow pause early (`unpauseBorrows`) and restore LTVs through the normal `K_LOOSEN` limits (or `overrideLTV` for borrow LTV).

## 2. Loss reserve: repaying bad debt

Context: hubs run with `CFG_DONT_SOCIALIZE_DEBT`; debt left on an account with no collateral stays there (lenders are not haircut) until repaid.

1. Monitoring flags an account with debt and zero collateral value after liquidation.
2. `K_RESERVE` (through the reserve Safe's Roles module) calls, as two module transactions:
   - `USDC.approve(hub, amount)` (spender must be one of the four hubs; `amount` within the role allowance);
   - `hub.repay(amount, account)`.
3. Verify `hub.debtOf(account) == 0`. The Roles scope (checked on the Arbitrum fork, `test/fork/LaunchRehearsal.t.sol`) rejects any other target, selector or spender.
4. If bad debt exceeds the reserve: `MS_ADMIN` turns loss-sharing back on (`setConfigFlags` without `CFG_DONT_SOCIALIZE_DEBT`) through the timelock; disclose.
5. Swept wrapper dividends also land in the reserve (§5); `MS_OPS` converts non-USDC balances to USDC or Prime hub shares.

## 3. Key leak or misuse, per role

First action for any `K_*` key: **`MS_OPS` revokes it** on the affected contract(s) (`revokeRole`; `MS_OPS` can revoke but never grant). New keys are granted by `MS_ADMIN` through the 48h timelock.

| Role | Worst case before revocation | Response |
| --- | --- | --- |
| `K_PRICE` | Pushes within the class bound go live; bigger moves stay Unconfirmed (no liquidations, bid capped at `L(1−h)`); pause any asset | Revoke. `MS_OPS` pauses affected assets, checks prices, unpauses. `MS_OPS` can pause liquidations (≤ 6h, repeatable) if a bad in-bound price was pushed |
| `K_CONFIRM` | Confirms a pending price | Revoke. Pause affected assets; liquidation pause if needed. Separate infrastructure from `K_PRICE` is what makes both keys necessary for an out-of-bound price |
| `K_TIGHTEN` | Mass LTV / cap cuts (liquidation cuts limited to 5 pts / 72h ramp / 24h per asset per hub; 3 demotions per 7 days) | Revoke. Mass restore (§4) |
| `K_LOOSEN` | Raises within limits (3 pts per week per asset, class ceilings, cap ceilings) | Revoke (in phase 1 it is the `MS_OPS` Safe itself). `K_TIGHTEN` / `overrideLTV` / `lowerCaps` back |
| `K_GUARD` | Pauses borrows and deposits for ≤ 24h per call, repeatedly | Revoke. `MS_OPS` ends the pauses (`unpauseBorrows`, `unpauseDeposits`) |
| `K_ALLOC` | Reallocates Earn between its hubs | Remove the allocator in Earn (`setIsAllocator`, Earn owner = the timelock: a 48h action). Curator (`MS_OPS`) can set caps to 0 meanwhile |
| `K_RESERVE` | Approves and repays up to the allowance | `MS_OPS` (Roles module owner) removes the role / zeroes the allowance |
| `MS_OPS` (Safe) | Everything in its row of §4, instantly | Signer rotation; `MS_ADMIN` revokes roles through the timelock; `MS_ADMIN` / `MS_OPS` can cancel timelock operations |

## 4. Mass restore after a bad mass tightening

1. Identify affected `(hub, asset)` pairs from `BorrowLtvLowered` / `LiquidationLtvLowered` / `CapsSet(by = K_TIGHTEN)` events.
2. `MS_OPS` batch (any size up to ~500 per call; measured in `test/bench/StewardGas.t.sol`):
   - `cancelRamp([...])` for liquidation-LTV cuts still ramping. Restores the liquidation LTV recorded before the first cut of each chain (never above the class ceiling).
   - `overrideLTV([...])` for borrow LTVs (up to the class ceiling, gap rule when raising).
   - `overrideCaps([...])` for caps (up to each vault's ceiling).
3. Ramps that already finished are restored through `K_LOOSEN` limits only (3 pts per week).
4. Run `ConfigCheck` and compare against the pre-incident snapshot.

## 5. Dividend sweep keeper

- `PoppieBalanceWrapper.sweep(token)` is permissionless and sends the wrapper's whole balance of `token` (never the underlying) to the factory's `dividendRecipient` (the reserve Safe).
- A keeper (any key, no role) watches distributing-token wrappers for stablecoin balances and calls `sweep(USDC)` (and any other payout token). Unswept balances are a monitoring alert (`ARCHITECTURE.md` §Monitoring).

## 6. Listing a batch of assets

1. Add rows to `config/assets.json` (schema `config/assets.schema.json`): mechanism, risk class, band hub index, seed, cap ceiling (token units).
2. **Stage 0 (≥ 48h ahead):** generate and sign the `MS_ADMIN` timelock `scheduleBatch` of `routerGovernor.setApprovedToken` (`BuildListingBatch` step `approvals`); execute after the delay.
3. **Stage 1 (deployer key):** wrappers (balance-changing and distributing; 2 × seed of the token), escrows, seed deposits, hook config, governance hand-off (step `stage1`). Escrows stay closed to deposits until stage 2 (the oracle does not list the token yet).
4. **Stage 2 (`MS_OPS`):** generate the Safe batches (step `stage2`): oracle listing, `addWrapper`, `addRoute`, `addResolvedVault`, cap ceilings, `steward.list`. Batches are packed under 20M gas each; sign and execute in order.
5. `K_PRICE` pushes and `K_CONFIRM` confirms first prices (a first price only goes live via `confirm`).
6. `ConfigCheck` with the stage-1 record: no diff.

Sizing limits per call (one Safe batch or one transaction): `oracle.listAssets` ~54k gas per asset; long-tail `steward.list` ~150k per asset; blue-chip `steward.list` ~330k per asset (4 hubs), so ≤ 80 blue chips per call.
