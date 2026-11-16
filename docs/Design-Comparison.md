# Zero-contract vs peripheral-contract design

*Nov 16, 2026. Plans: `docs/zeroContracts/Poppie-Arbitrum-Hub-Architecture-Governance-Plan.md` and `docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`. Metrics: `docs/Risk-Metrics.md`. Contract specifications: `docs/peripheralContracts/Peripheral-Contracts.md`.*

Both designs keep the audited v1 oracle and adapter and every stock Euler contract unchanged, and both use Euler's emergency governor (tighten-only emergency key) and cap steward. They differ only in whether Poppie adds five small contracts in slots the core already exposes. Everything else (issuers, keeper and prices, liquidity policy, hubs, rollout) is the same.

## In one line

- **Zero-contract:** nothing new to audit and no Poppie code in the borrow path, but several risks are bounded only by policy, by keeping caps tight, or not at all.
- **Peripheral:** bounds those risks on-chain, at the cost of about five small contracts to audit, a Poppie hook in the borrow path, and batched borrows for integrators.

## Gap by gap

| ID | Gap | Zero-contract | Peripheral | Bounded better by |
| --- | --- | --- | --- | --- |
| G1 | **Fast loss** before anyone acts (unbacked collateral, bad price, stolen issuer key) | Borrow cap kept a set headroom above borrows, raised daily by the cap steward | Hourly borrow limit per hub (P1); caps sized to exit depth only | Peripheral: no daily raises, no "cap reached" on busy days |
| G2 | **Response speed** | Emergency key (caps, LTVs) in seconds; optional Euler guardian hook (fixed duration, cooldown) | Same emergency key; renewable guardian pauses per hub and per escrow (P1, P2) | Similar; peripheral pauses are renewable and per escrow |
| G3 | **Compromised Oracle Safe** | Unbounded (Safe), or every admin action delayed (timelock) | Moves within ±X% instant, larger ones delayed or second-approved (P3) | **Peripheral**: the largest risk the zero-contract design can't bound without slowing every fix |
| G4 | **Stolen keeper key** | Keeper Safe with Zodiac Roles and several keys; a stolen key can still pause every asset | Forwarder with several keys and a daily pause budget (P4) | Peripheral |
| G5 | **`MS_OPS` power** | Emergency governor; optional ≥1-day timelock on loosening | Same | Equal |
| G6 | **Route overwrite** | All router changes instant, or all timelocked (listings too) | Listings instant; overwrites timelocked (P5) | Peripheral |
| G7 | **Sanctions and stolen funds** | Issuer-token and USDC lists; app and SDK screening; direct callers not screened | Hooks block listed borrowers, receivers and depositors, also on direct calls; optional account freeze (counsel) | Peripheral |
| G8 | **Issuer pause windows** | App and SDK only; direct callers rely on the issuer's own pause | Enforced on-chain (P2) | Peripheral |
| G9 | **Origination fee** | SDK only; direct callers pay none | Enforced on every borrow (P1); same batch shape | Peripheral |
| G10 | **Flash loans** | On, free; can be paused or disabled | On/off/pause/fee (P1) | Peripheral |
| G11 | **Account concentration** | Alert only | Optional debt cap per account (easy to split) | Marginal |
| G12 | **`MS_OPS` signing load** | Cap steward for bounded cap changes; daily headroom raises | Cap steward; no daily headroom raises | Peripheral |

## Neither design can

- seize, move or return funds;
- bound issuer powers (mint, burn, multiplier, upgrades) beyond caps and monitoring;
- price borrowing and liquidation differently, or pause a name without wiping its price;
- liquidate a stale name, or create exit liquidity;
- catch an attacker before they are listed;
- stop Arbitrum's Security Council acting on any contract;
- stop `MS_OPS` changing vault settings (instantly, unless timelocked).

## What the zero-contract design saves

- No new audit scope or audit time.
- No Poppie code in the borrow, deposit or push path: a Poppie bug can't block them.
- Integrators call EVK directly; no batching required.
- Less gas; fewer keys and parameters.
- Launch sooner. Every peripheral contract can still be added later, one at a time, without touching the core.

## What the peripheral design costs

- About five contracts of roughly 100–250 lines each (estimated) to write, test on the EVK harness and audit.
- A hook bug can block borrowing or deposits until uninstalled; uninstalling removes its protection. Repay and liquidation are never hooked.
- Every borrow must be an EVC batch with the fee borrow.
- Guardian, scheduler and denylist keys to secure.
- More to explain to users and regulators: the more Poppie can block, the more it may be expected to.

## A path between them

Launch as the zero-contract design and add contracts as each passes audit, in the order that removes the most risk: P3 (oracle admin), then P1 (hub guard), then P4, P5 and P2. Each is independent.
