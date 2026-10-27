# Poppie on Arbitrum: Smart Contract Specification

*Status: second draft, refreshed Oct 27 2026 for the decisions in `docs/ARCHITECTURE.md` and the v2 plan. Companion to the Hub Architecture & Governance Plan and the Problems doc. If they conflict, the plan wins for design intent; this spec wins for interfaces. Function names marked "proposed" are fixed when the interface files land (POP-5).*

## 1. Scope

This spec covers everything Poppie deploys or configures on Arbitrum. Euler core (EVC, EVK factory and implementation, lenses, swapper) is used at Euler's canonical Arbitrum addresses and is out of scope.

| Category | Components | Work |
| --- | --- | --- |
| Off the shelf | Hubs and escrow vaults (EVK), EulerRouter, Kink IRMs, Euler Earn, Governor (AccessControl), timelock, USDC/USD fixed-rate oracle, Safe + Roles module | Configuration only |
| Adapted from `gfx-labs/poppie-oracle` | `PoppieEulerOracle` v2, `PoppieEulerAdapter` v2 (three-state) | Modify existing code |
| New | `PoppieFeeRouter`, `PoppieHubHook`, `PoppieEscrowHook`, `PoppieRiskSteward`, `PoppieRouterGovernor`, `PoppieBalanceWrapper`, `PoppieWrapperFactory` | New code |

Estimated custom Solidity: 1,500–2,500 lines (the estimate predates the wrapper, the factory and the steward override). The highest-risk components are the three-state adapter and the fee router with its hub hook.

**EVK constraints this design relies on** (checked against `euler-vault-kit`; re-verify against the pinned Arbitrum version in POP-5 and POP-12):

- Each vault has exactly one hook target and a bitmask of hooked operations (`setHookConfig(address, uint32)`). All hook logic for one vault must live in one contract.
- The hook is called before the operation, with the original calldata plus the authenticated caller appended (20 bytes).
- `OP_VAULT_STATUS_CHECK` is hookable. It runs at the end of every operation, or at the end of the EVC batch, with the EVC as the appended caller.
- Account checks for borrow, withdraw and transfer value collateral at the bid (`getQuotes`). Liquidation uses the mid (`getQuote`) for the health check, discount and seizure.
- A liquidation seizes collateral by calling `transfer` on the collateral vault through `evc.controlCollateral`, so a hook on the escrow vault's `OP_TRANSFER` also sees liquidations.
- `setLTV(collateral, borrowLTV, liquidationLTV, rampDuration)`: a raise takes effect at once (a ramp is rejected); a cut can ramp. EVK remembers only the liquidation LTV in force just before the latest `setLTV`, and a new call restarts the ramp from the current ramped value. The steward therefore passes the remaining ramp time on every call, and records its own baseline (section 3.6).
- `setCaps(supplyCap, borrowCap)` takes EVK's 16-bit AmountCap encoding: a lossy format in which raw 0 means unlimited. "Zero" is encoded as raw 1.
- `setConfigFlags(flags)`; `feeReceiver()` is readable on every vault.
- `borrow(type(uint256).max, ...)` borrows all available cash.

## 2. Deployment layout

| Item | Count | Configuration |
| --- | --- | --- |
| Hubs (USDC borrow vaults) | 4: Prime, M1, M2, M3 | Oracle = EulerRouter; unit of account = USD (`0x…0348`); IRM per hub; `CFG_DONT_SOCIALIZE_DEBT` set; hook target = `PoppieHubHook`; **fee receiver set and non-zero** (it receives both the interest fee and the origination fee) |
| Escrow vaults | 1 per asset | Non-upgradeable factory proxy; governed; borrowing disabled (borrow cap raw 1, never raw 0); hook target = `PoppieEscrowHook`; seed deposit at creation; created by the deployer key (see Listing flow) |
| Balance wrappers | 1 per balance-changing or dividend-paying token | Created by `PoppieWrapperFactory`; immutable; the escrow vault's `asset()` is the wrapper |
| Wrapper factory | 1 | Admin `MS_ADMIN` via timelock (sets the dividend recipient = the reserve Safe) |
| EulerRouter | 1 | Governor = `PoppieRouterGovernor`; route `(token, USD)` → `PoppieEulerAdapter`; `(USDC, USD)` → fixed-rate oracle; each wrapper registered as a resolved vault (wrapper → token); each escrow vault registered as a resolved vault (escrow → wrapper or token) |
| IRMs | 1 per hub | Kink IRM with a rate floor (proposed: 2/3/4/5%) |
| Euler Earn | 2: Prime Earn, Yield Earn | Curator `MS_OPS`, allocator `K_ALLOC` |
| Timelock | 1 | 48h; proposer `MS_ADMIN`; canceller `MS_OPS` |
| Loss reserve | 1 Safe + Roles module | Owner `MS_OPS`; `K_RESERVE` role (section 3.8); also receives swept wrapper dividends |
| Deployer key | 1 (KMS) | Creates wrappers and escrow vaults and pays their seed deposits; holds no role after setup. Flagged for review (POP-19) |

**Listing rules:** blue-chip escrow vaults are LTV-listed in every hub. Long-tail escrow vaults are listed in exactly one hub, the one for their band.

**Listing flow (two stages):**
1. *Deployer key:* deploy the wrapper if the token needs one, create the escrow vault, make the seed deposits, set the hook config, hand governance to the Governor. This stage needs no trust: the router governor verifies the result.
2. *`MS_OPS` Safe batch:* `oracle.listAssets`, `routerGovernor.addWrapper` (wrapped tokens only), `addRoute`, `addResolvedVault`, then `steward.list`.

## 3. Contract specifications

### 3.1 `PoppieEulerOracle` v2

Price store and state machine. Extends the BSC oracle. **Changes from BSC:** it keeps the last confirmed price through pauses; it adds class bounds, the unconfirmed state, `K_CONFIRM` and the `n`-push fallback; it drops the cumulative anchor cap, since `K_PRICE` is trusted; and it lists tokens with compact ids so a full refresh fits in few bytes.

**Storage per asset** (two slots)

| Field | Meaning |
| --- | --- |
| `lastPrice`, `lastPriceTs` | Last confirmed (live) price and when it was pushed. `lastPrice == 0` means no price has ever been confirmed |
| `pendingCount`, `pendingDir` | Unconfirmed move: consecutive push count, direction (+1 or −1). Same slot as the fields above, so a Live push is one storage write |
| `pendingPrice`, `pendingTs` | Latest pushed unconfirmed price and its time. Written only while a move is pending |
| `paused` | Admin or keeper pause |
| `priceClass` | Blue chip, M1, M2 or M3. Sets `h` (the haircut, which is also the reopen bound). Separate from the steward's risk class |
| `decimals`, `listed`, `id` | Decimals of the underlying token (≤ 18), listing flag, and a `uint16` id assigned at listing |

Global (one slot): `maxPriceAge` (1h), `n` (fallback push count, ≥ 2), `minPendingSpacing`, and `hBps` for each of the four price classes.

**State, derived on every read**

| State | Condition |
| --- | --- |
| Closed | `paused`, or `now − max(lastPriceTs, pendingTs) > maxPriceAge` |
| Unconfirmed | Not closed, and `pendingCount > 0` |
| Live | Otherwise |

**Listing: `listAssets(tokens[], classes[])`**, role `MS_OPS`. Add-only. Lists **underlying tokens only, never wrappers.** Assigns each token a `uint16` id, reads its `decimals()` (must be ≤ 18) and sets its price class. An asset has no price until the first confirmation.

**`keeperPushPrices(assets[], prices[])`**, role `K_PRICE`. For each asset, with `p` the pushed price and `L = lastPrice`:

1. If `L == 0` (no confirmed price yet): set `pendingPrice = p`, `pendingTs = now`, `pendingCount = 1`. Only `confirm` can take it live; the `n`-push fallback is disabled while `L == 0`.
2. Else if `|p − L| ≤ h × L`: set `lastPrice = p`, `lastPriceTs = now`, clear the pending fields. **→ Live**
3. Otherwise, with `dir = sign(p − L)`:
    - If `pendingCount > 0` and `now < pendingTs + minPendingSpacing`: the push does not count (default: it is ignored for this asset and changes no pending state; POP-6 may refine).
    - Else if `pendingCount > 0` and `dir == pendingDir`: increment `pendingCount`.
    - Else: `pendingCount = 1`, `pendingDir = dir`.
    - Set `pendingPrice = p`, `pendingTs = now`.
    - If `pendingCount ≥ n`: promote. Set `lastPrice = p`, `lastPriceTs = now`, clear pending. **→ Live**

A push to a paused asset reverts. Duplicate entries for one asset in a single batch, or several pushes in one block, cannot promote a price, because of `minPendingSpacing`.

**`keeperPushPacked(bytes)`**, role `K_PRICE`. The same logic through the same internal function. Each entry is 14 bytes: `uint16 id | uint96 price` (18-decimal USD). A full 500-asset refresh is about 7 KB instead of about 32 KB.

**`confirm(asset, price)`**, role `K_CONFIRM`.
- Requires the asset not paused, `pendingCount > 0`, `price == pendingPrice`, and `now − pendingTs ≤ maxPriceAge`.
- Promotes the pending price to live.

**`confirmBatch(assets[], prices[])`**, role `K_CONFIRM`. Applies `confirm` to each entry. Default: all-or-nothing; one stale or changed entry reverts the batch.

**`pauseAssets(assets[])`**, roles `K_PRICE` or `MS_OPS`. Sets `paused`. Keeps `lastPrice`.

**`unpauseAssets(assets[])`**, role `MS_OPS`. Clears `paused`. The next push follows the normal rules: within `h` it goes live, beyond `h` it becomes unconfirmed. After a corporate action, `MS_OPS` unpauses only once the token's balance or multiplier and the price both reflect the action (runbook).

**Admin**, role `MS_ADMIN` via timelock: set a price class or the `h` of a class, `maxPriceAge`, `n` (≥ 2), `minPendingSpacing`, and role holders.

**Events:** `AssetListed`, `PriceLive`, `PricePending(asset, price, count, dir)`, `PriceConfirmed(asset, price, by)`, `PricePromotedByPersistence`, `AssetPaused`, `AssetUnpaused`, `ParamsUpdated`.

**Views:** `state(asset)`, `getAssetData(asset)`, `getQuoteData(asset)` (state, `L`, `P`, `h` and decimals in one call), and batch views for monitoring. The adapter and `PoppieEscrowHook` use these.

### 3.2 `PoppieEulerAdapter` v2 (three-state)

An Euler `IPriceOracle` adapter, one per deployment, for every equity. Immutable, with no admin. It accepts only `quote == address(840)` (USD) and a base that is a listed token; otherwise it reverts. The router resolves escrow-vault shares to the wrapper (if any) and then to the underlying token before calling it.

| State | `getQuote` (mid) | `getQuotes` bid | `getQuotes` ask |
| --- | --- | --- | --- |
| Live | `L` | `L` | `L` |
| Closed | reverts `PriceUnavailable` | `L × (1 − h)` | `L` |
| Unconfirmed (`P` = pending price) | reverts `PriceUnconfirmed` | `min(P, L × (1 − h))` | `max(P, L)` |

- **Invariant:** bid ≤ mid ≤ ask whenever the mid is defined. In Closed and Unconfirmed the mid reverts, and bid ≤ ask always holds.
- **Invariant:** the bid never rises above `L × (1 − h)` before a move is confirmed, whichever way the price moved.
- While `L == 0` the bid is 0, so nothing can be borrowed against an asset before its first confirmation.
- Prices scale to 18 decimals against `address(840)`, as on BSC. The bid rounds down and the ask rounds up. The ask on collateral is never used by EVK; it's defined only for interface completeness.

### 3.3 `PoppieFeeRouter`

Collects the origination fee without operator rights.

**Flow (one EVC batch):**
1. `hub.borrow(amount, receiver = PoppieFeeRouter)`, on behalf of the account.
2. `PoppieHubHook` (`OP_BORROW`) validates the borrow and calls `router.recordPending(hub, account, amount)`.
3. `router.forward(hub, to)`, called through `evc.call` on behalf of the same account.
4. At the end of the batch, `PoppieHubHook` (`OP_VAULT_STATUS_CHECK`) requires `router.pendingTotal(hub) == 0`.

**Functions**

| Function | Caller | Behaviour |
| --- | --- | --- |
| `recordPending(hub, account, amount)` | `PoppieHubHook` only | Adds to transient `pending[hub][account]` and `pendingTotal[hub]` |
| `forward(hub, to)` | Account, via the EVC | Resolves the account with `evc.getCurrentOnBehalfOfAccount(address(0))`, requires `pending > 0`, sends `fee = ceil(pending × feeBps[hub] / 10_000)` to `hub.feeReceiver()` and `pending − fee` to `to`, then clears pending. Reverts if `hub.feeReceiver()` is the zero address |
| `setFeeBps(hub, bps)` | `MS_OPS` | Requires `bps ≤ 100` (hard cap) |
| `sweep(token, to)` (proposed) | `MS_OPS` | Recovers tokens sent to the router by mistake |

- There is **no treasury address in the router.** The fee goes to the hub's own fee receiver, which also receives that hub's interest fee. A change to the receiver (through the Governor) applies from the next `forward`.
- Pending state lives in transient storage only. Invariant: no transaction changes the router's token balance.
- The router is non-upgradeable.
- **Fee basis:** the fee applies to every borrow, on the borrowed amount. Repaying and re-borrowing pays again; liquidations, repayments, withdrawals and `pullDebt` never pay. (A fee on net-new debt only was considered and not adopted; see the plan.)

### 3.4 `PoppieHubHook`

The single hook target for all four hubs. It combines the fee hook and the pause hook. It rejects any call from a vault that is not a registered hub; hubs are registered by `MS_ADMIN` via the timelock (`registerHub`, proposed).

| Operation | Behaviour |
| --- | --- |
| `OP_BORROW` | Revert if the hub is paused. Decode `borrow(amount, receiver)`: require `receiver == PoppieFeeRouter` and `amount != type(uint256).max`. Call `router.recordPending(hub, caller, amount)`. |
| `OP_VAULT_STATUS_CHECK` | Require `router.pendingTotal(hub) == 0`. Must pass whenever nothing is pending, including during liquidations, repays and deposits. |
| `OP_FLASHLOAN` | Always revert (flash loans off at launch) |
| `OP_LIQUIDATE` | Revert only while a liquidation pause is active |
| Never hooked | `OP_REPAY`, `OP_REPAY_WITH_SHARES`, `OP_PULL_DEBT`, `OP_WITHDRAW`, `OP_REDEEM`, `OP_DEPOSIT`, `OP_MINT` |

- **Borrow pause:** `pauseBorrows(hub, duration)`, role `K_GUARD`, `duration ≤ 24h`. Expires automatically. **No cooldown:** `K_GUARD` can pause again as soon as a pause expires, so the limit is per call. The control on a misused key is `MS_OPS` revoking it, plus alerts.
- **Liquidation pause:** `pauseLiquidations(hub, duration)`, role `MS_OPS`, `duration ≤ 6h` per call. Calls can be chained back to back, with no aggregate cap. Policy: confirmed oracle fault only.
- **Consequence:** a direct, un-batched borrow always reverts, because the status check runs before the router can forward. Integrators must use EVC batches.

### 3.5 `PoppieEscrowHook`

The single hook target for all escrow vaults. Escrow vaults are non-upgradeable factory proxies.

| Operation | Behaviour |
| --- | --- |
| `OP_DEPOSIT`, `OP_MINT`, `OP_SKIM` | Revert if the oracle state of the underlying token is Closed, or if deposits are paused for that vault |
| `OP_TRANSFER` | The same, except while `evc.isControlCollateralInProgress()` is true, so liquidations can seize collateral during a deposit pause |
| Never hooked | `OP_WITHDRAW`, `OP_REDEEM`, `OP_LIQUIDATE` (on the hub side) |

- **Asset resolution:** the hook first resolves the vault's `asset()`. If it is a wrapper (`factory.isWrapper`), it checks the oracle state of the wrapper's underlying token, which is the only thing the oracle lists.
- **Deposit pause:** `pauseDeposits(vault, duration)`, role `K_GUARD`, `duration ≤ 24h` per call, with the same rules as the borrow pause: no cooldown, per vault.
- Blocking `OP_TRANSFER` while closed also blocks transfers between a user's own sub-accounts for that name. That's acceptable, since it only applies during closures.

### 3.6 `PoppieRiskSteward`

Holds the Governor roles for `setLTV` on hubs and `setCaps` on hubs and escrow vaults. It enforces value limits that the Governor alone can't.

**Stored:** per asset, token → wrapper (if any) → escrow vault, risk class, band hub and cap ceilings; per (asset, hub), the liquidation LTV in force before the current chain of cuts (see ramp cancel); globally, the hub list and each hub's band.

**Class ceilings** (borrow / liquidation LTV): blue chip 70/75, M1 50/58, M2 45/52, M3 35/42. Minimum gap between the two: 5 pts for blue chip, 8 pts for long tail.

**Cap ceilings** are set per asset by `MS_OPS` from measured exit depth, and `MS_OPS` can raise them instantly. They bind `K_LOOSEN`, which cannot change them, and are the **only on-chain limit on its cap growth**, so they must be kept conservative. An off-chain alert on every cap raise must exist before `K_LOOSEN` is enabled. Escrow vaults' borrow caps stay at zero and the steward never raises them.

**Blue-chip sync:** a change to a blue-chip asset is applied to every hub in the same call, whichever hub is passed, so settings cannot drift apart.

| Function | Role | Limits |
| --- | --- | --- |
| `lowerBorrowLTV(hub, asset, ltv)` | `K_TIGHTEN` | Any amount, instant. Batched, with no limit on how many assets |
| `lowerLiquidationLTV(hub, asset, ltv)` | `K_TIGHTEN` | ≤ 5 pts per call; ramp ≥ 72h; once per asset per hub per 24h. No limit on how many assets are cut per day |
| `lowerCaps(vault, supply, borrow)` | `K_TIGHTEN` | Down to current usage; below that needs `MS_OPS` (`overrideCaps`). Batched |
| `raiseLTV(hub, asset, borrow, liq)` | `K_LOOSEN` | ≤ 3 pts per change; once per asset per 7 days; ≤ class ceiling; gap rule |
| `raiseCaps(vault, supply, borrow)` | `K_LOOSEN` | Up to the asset's cap ceiling, with **no rate limit** |
| `promote(asset, hubs[])` | `K_LOOSEN` | Lists a newly promoted blue chip in every hub, in one call, at launch limits. All-or-nothing |
| `demote(asset)` (proposed) | `K_TIGHTEN` | In hubs the asset is leaving: borrow LTV to 0 at once; liquidation LTV ramps to 0 over at least (cut ÷ 5 pts) × 24h. In the band hub it stays in: borrow LTV drops to the new class ceiling at once; liquidation LTV ramps down over at least (cut ÷ 5 pts) × 24h, never under 72h. Own rate limit (proposed: ≤ 3 per rolling 7 days) |
| `list(asset, escrow, hub, class)` | `MS_OPS` | New listing: LTV ≤ 50% of the class ceiling, supply cap ≤ 25% of the cap ceiling |
| `setCapCeiling(vault, supply)` (proposed) | `MS_OPS` | Sets or raises a cap ceiling, instantly |
| `overrideLTV(hub, asset, borrow)` (proposed) | `MS_OPS` | Sets the borrow LTV anywhere up to the class ceiling, in batches, without the weekly limit. The borrow LTV cannot exceed the liquidation LTV, and the gap rule applies. Does not raise the liquidation LTV |
| `overrideCaps(vault, supply, borrow)` (proposed) | `MS_OPS` | Sets caps anywhere up to the cap ceilings, in batches, without a rate limit |
| `cancelRamp(hub, asset)` (proposed) | `MS_OPS` | For a liquidation-LTV cut or demotion still ramping: restores the liquidation LTV recorded before the first cut of the chain, never above the class ceiling. Batched |
| `emergencyLowerLiquidationLTV` | `MS_OPS` | ≤ 15 pts; ramp ≥ 12h |

- **Replaced from the first draft:** the undo (`restore`) design, the "≤ 10 assets per 24h" budget, the global "≤ 50 tightening actions per hour" limit, and the "+25% per 7 days" cap limit are all removed. The remaining defences are the per-asset limits, ramp cancel, the override and alerts.
- **Chain of cuts:** a chain starts when a liquidation-LTV cut begins while no ramp is active. The steward records the liquidation LTV at that moment and keeps it until the ramp ends. Ramp cancel restores that value.
- **Ramps are never shortened:** every `setLTV` call passes the remaining ramp time.
- **Cap comparisons** use resolved AmountCap amounts. A cap written to EVK is rounded down after encoding and is never raw 0.
- **Issuer and underlying-stock exposure caps are enforced off-chain only**, not in the steward.
- **Loosening in rollout phase 1:** `K_LOOSEN` is held by the `MS_OPS` Safe. In phase 2 it moves to a KMS key through the timelock. There is no on-chain switch.

### 3.7 `PoppieRouterGovernor`

The governor of the EulerRouter. All three add functions are add-only.

| Function | Role | Rule |
| --- | --- | --- |
| `addRoute(token)` | `MS_OPS` | `token` must be on the approved token list; route must be unset; adapter is always `PoppieEulerAdapter` |
| `addWrapper(wrapper)` | `MS_OPS` | `wrapper` must come from `PoppieWrapperFactory` (`isWrapper`), wrap an approved token, and not be registered. Registers wrapper → token as a resolved vault |
| `addResolvedVault(escrow)` | `MS_OPS` | Must be unset. `escrow` must be a **non-upgradeable** factory proxy, with no oracle and no unit of account, the Poppie Governor as `governorAdmin`, the expected hook target and hooked operations, and an `asset()` that is an approved token or a registered wrapper |
| `setApprovedToken(token, bool)` | `MS_ADMIN` via timelock | Approved token list |
| `execute(call)` | `MS_ADMIN` via timelock | Any other router change, including overwrites |

### 3.8 Loss reserve (configuration, no code)

- A Safe with the Roles module. `K_RESERVE` may only:
    - call `USDC.approve(hub, amount)` for the four hubs;
    - call `hub.repay(amount, receiver)`.
- Per-call and daily allowances are set in the Roles module.
- Withdrawals from the reserve and role changes: `MS_OPS` only.
- Loss-sharing (`CFG_DONT_SOCIALIZE_DEBT`) is turned back on by `MS_ADMIN` via timelock, for the case where bad debt exceeds the reserve.
- The reserve is also the recipient of swept wrapper dividends (section 3.9). It may then hold tokens other than USDC, which `MS_OPS` converts to USDC or Prime hub shares.

### 3.9 `PoppieBalanceWrapper` and `PoppieWrapperFactory`

Euler doesn't support tokens whose balance changes without a transfer, and an escrow vault can't recover tokens sent to it. Balance-changing tokens (xStocks; Reality on splits) and dividend-paying tokens (Reality, Dinari) are therefore wrapped, and the escrow vault holds the wrapper.

**`PoppieBalanceWrapper`**: immutable, ERC-4626-style, one per token.
- Shares never change in number on their own. `convertToAssets` follows the wrapper's own balance of the token, so positive and negative rebases are shared pro rata.
- Deposits mint shares from the balance actually received.
- A seed deposit at creation plus a virtual share offset prevent first-depositor inflation. Seed shares are locked permanently.
- **No skim:** tokens donated to the wrapper raise the value of every share.
- **`sweep(token)`** (proposed): permissionless. It rejects the wrapper's own underlying token, and sends the whole balance of any other token to the recipient stored in the factory (the reserve Safe). This is how dividends paid in stablecoins reach the reserve. Depositors forgo dividends while deposited, disclosed at deposit. Flagged for review (POP-20).
- The wrapper has no other admin function.

**`PoppieWrapperFactory`**
- Creates wrappers, pulling the seed deposit from the caller (a deployer key; flagged for review, POP-19), with a minimum seed.
- Keeps `isWrapper[wrapper]` and `wrapperOf[token]`, and allows one wrapper per token.
- Holds the dividend recipient, which only `MS_ADMIN` can change, via the timelock.
- Creation is callable by any address (default; confirm in POP-8), because the router governor verifies what gets registered.

## 4. Roles

| Role | Custody | Contracts it touches |
| --- | --- | --- |
| `K_PRICE` | KMS | Oracle: push (both formats), pause |
| `K_CONFIRM` | KMS, separate infrastructure | Oracle: confirm, confirm batch |
| `K_TIGHTEN` | KMS | Steward: lower functions, `demote` |
| `K_LOOSEN` | `MS_OPS` Safe in phase 1; a KMS key in phase 2 (via timelock) | Steward: raise and promote |
| `K_ALLOC` | KMS | Earn: reallocate |
| `K_GUARD` | KMS | Hub hook and escrow hook: time-limited pauses (≤ 24h per call, no cooldown) |
| `K_RESERVE` | KMS | Reserve Safe: repay only |
| `MS_OPS` | Safe 3-of-5 | Unpause, listing, fees, liquidation pause (≤ 6h per call, repeatable), emergency LTV cuts, steward override, ramp cancel and cap ceilings, Earn caps, reserve withdrawals, timelock cancel, key revocation |
| `MS_ADMIN` | Safe 4-of-7 | Everything structural, via the 48h timelock, including the dividend recipient and hub registration |

`MS_OPS` can revoke any `K_*` role but cannot grant one. The off-chain rule for `K_CONFIRM` (detect, verify independently, confirm or escalate, log) is specified in the plan. It isn't enforceable on-chain.

## 5. Parameters (proposed starting values)

| Parameter | Value |
| --- | --- |
| `h` (haircut and reopen bound) | Blue chip 10%, M1 15%, M2 20%, M3 30% |
| `n` (fallback pushes) | 3 (setter enforces ≥ 2) |
| `minPendingSpacing` | 10 minutes |
| `maxPriceAge` | 1h |
| Max liquidation discount | Prime 8%, M1 10%, M2 15%, M3 20% |
| Interest fee | Prime 10%, M1 15%, M2 20%, M3 25% |
| Origination fee | Prime 10 bps, M1 15 bps, M2 25 bps, M3 35 bps (cap 100 bps) |
| Liquidation-LTV cut | ≤ 5 pts per call; ramp ≥ 72h; once per asset per hub per 24h |
| `demote` rate limit | ≤ 3 per rolling 7 days |
| `K_GUARD` pause | ≤ 24h per call, no cooldown |
| `MS_OPS` liquidation pause | ≤ 6h per call, repeatable |
| Timelock | 48h |

## 6. Invariants and tests

| Area | Invariant or test |
| --- | --- |
| Adapter | bid ≤ mid ≤ ask; mid reverts in Closed and Unconfirmed; the bid never exceeds `L × (1 − h)` before confirmation; the bid is 0 while `L == 0`; fuzz every state transition |
| Oracle | promotion only via `confirm` or `n` correctly spaced same-direction pushes; the first price goes live only via `confirm`; a push within the bound resets pending; pause keeps `lastPrice`; listing takes underlying tokens only; the packed and ABI pushes behave identically |
| Fee router and hub hook | direct borrow reverts; a batched borrow + forward succeeds and the fee lands at `hub.feeReceiver()`; a zero fee receiver reverts; the status check passes with nothing pending (liquidate, repay, deposit); `max` borrows revert; flash loans revert; no transaction changes the router's balance; `forward` can't be called for another account; calls from non-registered vaults are rejected; `K_GUARD` can re-pause as soon as a pause expires; liquidation pauses can be chained |
| Escrow hook | every deposit route (deposit, mint, skim, transfer) is blocked while closed; withdraw and redeem are never blocked; wrapped assets are resolved to the underlying token; liquidation seizure succeeds during a deposit pause |
| Wrapper | positive and negative rebases are shared pro rata; no first-depositor inflation; the share count is unaffected by rebases; `sweep` never moves the underlying token and sends only to the factory's recipient; pricing works through escrow → wrapper → token |
| Steward | every bound and rate limit, at its boundary; `promote` is all-or-nothing; ramps are never shortened; stacked cuts followed by ramp cancel restore the original baseline; the override and ramp cancel work in batches of 500; the removed limits no longer apply |
| Router governor | add-only; non-approved tokens, non-factory wrappers, upgradeable or misconfigured escrow vaults are rejected |
| Configuration | diff every hub and escrow vault against the intended parameters before and after each listing batch; fail on a zero fee receiver |
| Scale | gas for `setLTV`, `LTVList()` and the lens with 300+ collaterals in one hub; pushes of 100, 250 and 500 assets in both formats; a 500-asset `confirmBatch` |

## 7. Build order

1. Foundation: dependencies, toolchain, interfaces and test harness
2. Oracle v2 and adapter v2 (extending `poppie-oracle`)
3. Fee router and hub hook (prototype the status-check behaviour early)
4. Balance wrapper and factory
5. Escrow hook
6. Router governor and risk steward
7. Deployment and listing scripts producing diffable batches
8. Integration, fork and scale tests
9. Spec and README reconciliation, static analysis
10. Audits: contracts, off-chain systems, economic review

Steps 2 to 6 can run in parallel once step 1 has landed.

## 8. Open items

- Hub-level caps: which role raises a hub's own supply and borrow caps, and within what bound. Section 3.6 covers escrow-vault caps only.
- Who can end a `K_GUARD` pause early (assumed `MS_OPS`).
- Whether `confirmBatch` should skip stale entries instead of reverting the whole batch.
- Whether a push that arrives inside `minPendingSpacing` should refresh `pendingPrice` (default: ignored).
- Seed deposit funding (POP-19) and dividend handling (POP-20) are flagged for review before launch.
- No cumulative per-day price cap is planned, given the trusted keeper. Revisit if the audit asks for one.
- No extra grace period after Arbitrum sequencer downtime: staleness closes the markets as usual.
