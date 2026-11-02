# Security notes and threat model (v2, for reviewers)

Scope and versions: `docs/AUDIT_SCOPE.md`. Behaviour: `docs/CONTRACT_SPEC.md`. Static analysis triage:
`docs/STATIC_ANALYSIS.md`. Operations: `docs/RUNBOOKS.md`.

## System context

- Chain: Arbitrum. Euler V2 core (EVC, EVK, Euler Earn, Governor, kink IRM) at canonical addresses; Poppie deploys its
  own EulerRouter, hooks, oracle and adapter, fee router, wrappers, router governor and risk steward.
- Borrow asset USDC; four hubs (Prime, M1, M2, M3) with `CFG_DONT_SOCIALIZE_DEBT`; one non-upgradeable escrow vault per
  collateral; balance-changing and dividend-paying tokens are wrapped first.
- Prices are pushed by a trusted keeper (`K_PRICE`); moves beyond a class bound need `K_CONFIRM` (separate
  infrastructure) or `n` spaced same-direction pushes. Liquidations use the mid (reverts unless Live); borrowing and
  withdrawals use the bid (haircut while Closed or Unconfirmed).
- No timelock on risk parameters (disclosed): they are bounded on chain by the steward and the oracle setters, and
  watched off chain. Structural changes go through a 48h timelock.
- Exposure rules (per issuer, per underlying, hub concentration) are enforced **off chain only**.

## Roles and trust

| Holder | Power | On-chain bound | Control |
| --- | --- | --- | --- |
| `K_PRICE` (KMS) | Push prices, pause assets | Class bound: bigger moves stay Unconfirmed; first price needs `K_CONFIRM` | `MS_OPS` revokes |
| `K_CONFIRM` (KMS, separate infra) | Confirm pending prices | Must match the pending price, not stale, asset not paused | `MS_OPS` revokes. Off-chain rule: verify independently, escalate if undecided, never confirm by default |
| `K_TIGHTEN` (KMS) | Lower LTVs and caps, demote | Liq. cuts ≤ 5 pts, ramp ≥ 72h and ≥ remaining, once per asset per hub per 24h; ≤ 3 demotions per 7 days | `MS_OPS` revokes; ramp cancel and override restore |
| `K_LOOSEN` (MS_OPS in phase 1) | Raise LTVs and caps, promote | ≤ 3 pts per week per asset, class ceilings, gap rule; caps ≤ per-vault ceilings | Cap-raise alert must exist before moving to a KMS key (phase 2) |
| `K_GUARD` (KMS) | Pause borrows / deposits ≤ 24h per call, no cooldown | Duration cap only | `MS_OPS` revokes and unpauses |
| `K_ALLOC` (KMS) | Reallocate Euler Earn | Earn caps (curator) | Earn owner (timelock) removes; curator zeroes caps |
| `K_RESERVE` (KMS) | Reserve Safe: `USDC.approve(hub, ≤ allowance)`, `hub.repay` | Zodiac Roles v2 scope | `MS_OPS` (Roles owner) |
| `MS_OPS` (Safe 3-of-5) | Unpause, listing, fees, oracle risk params, liquidation pause (≤ 6h, repeatable), steward override / ramp cancel / emergency cut / cap ceilings, Earn curator, timelock cancel, `K_*` revocation | Steward class ceilings and cap ceilings; fee ≤ 100 bps; oracle setter bounds | Trusted. Cannot grant roles |
| Timelock (48h; MS_ADMIN proposes/executes, MS_OPS cancels) | `DEFAULT_ADMIN_ROLE` on every Poppie contract; Governor admin **and wildcard** (any vault governance call, including `setLTV`/`setCaps` outside the steward); router `execute`; approved tokens; dividend recipient; Earn owner (after accepting) | 48h delay | Trusted; public queue |
| Deployer key (KMS) | Creates wrappers and escrows, pays seeds | Holds no role after setup (ConfigCheck) | Escrow seed shares and (until the timelock accepts) Earn ownership remain with it; see residual risks |
| Euler | EVK factory admin can upgrade the hub implementation (hubs are upgradeable factory proxies); escrows are not upgradeable | — | Trust in Euler governance |

## Areas to scrutinise

1. **Three-state adapter**: bid ≤ mid ≤ ask; mid reverts unless Live; bid ≤ `L × (1 − h)` before confirmation; rounding
   (bid and mid down, ask up); `L == 0` gives a zero bid.
2. **Oracle state machine**: promotion only via `confirm` or `n` spaced same-direction pushes; `minPendingSpacing`;
   packed-push decoding (id 0 rejected); a paused or unlisted entry reverts the whole push batch.
3. **Fee router + hub hook**: transient pending accounting, `forward` only via the EVC on behalf of the borrower,
   status-check gate on every operation, router never keeps funds (`sweep` excepted), `max` borrow and flash loans
   blocked.
4. **Escrow hook**: every deposit route (deposit, mint, skim, transfer, `transferFrom`, `transferFromMax`) blocked while
   Closed or paused; the `controlCollateral` bypass (liquidation seizure) skips both checks.
5. **Risk steward**: ramp math mirrors EVK `LTVConfigLib` (`_ramped`); the remaining ramp is passed on every write; chain
   baselines and ramp cancel; blue-chip fan-out; AmountCap encode/resolve (never raw 0); rate limits; demote ring buffer.
6. **Router governor**: escrow verification (factory proxy, non-upgradeable, no oracle / unit of account, governor,
   hook config, allowed asset), add-only routes.
7. **Wrapper**: rebases pro rata, inflation resistance (offset 6 + seed), `sweep` cannot move the underlying.

## Known design decisions (not bugs)

- A direct, un-batched borrow always reverts (fee router design). Integrators use EVC batches.
- A pause call replaces the expiry (it can shorten an active pause); unpause of a non-paused vault is a no-op.
- `confirmBatch` is all-or-nothing; a push inside `minPendingSpacing` is ignored.
- Launch LTVs are exactly 50% of the class ceilings and sit inside the gap rule; the gap rule is enforced only when a
  borrow LTV is raised.
- Blue-chip steward changes apply to every hub where the escrow is a recognised collateral.
- No cumulative daily price cap and no sequencer-downtime grace (the keeper is trusted; staleness closes markets).
- Exposure caps are off chain.

## Residual risks

- **Split while Closed:** if a split lands while the asset sits Closed on its pre-split price, the bid overvalues
  collateral by `2 × (1 − h)` until the keeper pushes (test `test_finding_splitWhileClosedOnStalePriceOvervaluesBid`).
  Runbook §1 (push at the action; cut LTVs and pause borrows beforehand).
- **Governor wildcard** lets the timelock bypass steward limits (48h delay, public queue).
- **Fee router `sweep`** sends the router's whole balance; called mid-batch it could take pending funds (MS_OPS only).
- **Batch sizes:** a 500-asset `lowerLiquidationLTV` is ~29M gas (Arbitrum block 32M); blue-chip `list` must be chunked
  at ≤ 80 per call; `oracle.listAssets` ~54k gas per asset.
- **Lens cost:** `VaultLens.getVaultInfoFull` on a hub with 500 collaterals costs ~51M gas, above the common 50M
  `eth_call` cap; frontends must page collaterals.
- **Open decisions** (`CONTRACT_SPEC.md` §8): M2/M3 ceilings vs the 8-pt gap rule; ramp cancel in a hub a demoted
  asset is leaving restores a liquidation LTV there; hubs added after launch get no existing blue chips; escrow seed
  shares and Earn ownership left with the deployer until handled at launch.
