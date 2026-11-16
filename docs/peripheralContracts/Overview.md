# Poppie v2 on Arbitrum: Overview (peripheral-contract design)

*Nov 16, 2026. Shared plan: `docs/Overview.md`. Plan: `docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`. Contract specifications: `docs/peripheralContracts/Peripheral-Contracts.md`. This design is the zero-contract design (`docs/zeroContracts/Overview.md`) plus five small Poppie contracts; only the differences are listed here. Comparison: `docs/Design-Comparison.md`.*

## What changes

- **Core contracts unchanged.** The audited oracle and adapter, and stock Euler, are used as they are. New contracts plug into slots those contracts already expose: vault hooks, the oracle's `admin` and `keeper` slots, and the router's governor.
- **New contracts (each optional and independent):**

  | Contract | Purpose |
  | --- | --- |
  | P1 hub guard (hook) | Limits new borrowing per hour; renewable guardian pause; sanctions screening; enforced origination fee; flash-loan policy |
  | P2 escrow guard (hook) | Enforces issuer pause windows on-chain; guardian deposit pause; sanctions screening; optional account freeze |
  | P3 oracle admin guard | Small price fixes instant, large ones delayed or second-approved |
  | P4 keeper forwarder | Several keeper keys; limits how many assets a keeper can pause |
  | P5 router governor | Listings instant; route overwrites timelocked |

## Control

| Who | Controls | Bounded by |
| --- | --- | --- |
| Keeper keys | Price pushes, asset pauses | The oracle's limits; at most N pauses per day (P4) |
| Guardian key | Pause borrows and deposits; cancel queued oracle changes; revoke keepers | Tighten only |
| Scheduler, denylist keys | Issuer pause windows; blocked addresses | Add only, bounded |
| Emergency, cap steward keys | As in the zero-contract design | Euler |
| Oracle Safe | Prices and oracle settings | ±X% per call instant; larger moves delayed or second-approved (P3) |
| Ops Safe | Hubs, LTVs, caps, listings | Its signers; route overwrites delayed (P5); can uninstall the hooks |
| Reserve Safe | Repays bad debt | Its signers |

## What it buys over the zero-contract design

- **Fast attacks are bounded by an hourly borrow limit**, so borrow caps don't have to sit just above borrows and be raised every day.
- **A compromised Oracle Safe can no longer set any price instantly**, while small corrections stay instant.
- **A stolen keeper key can no longer wipe every price.**
- **Sanctioned addresses are blocked on-chain**, including direct callers; an account freeze is available if counsel requires it.
- **The origination fee is enforced**, not only charged by the SDK.
- **Issuer pause windows are enforced on-chain.**
- **Listings stay instant while route overwrites are delayed.**

## What it costs

- About five small contracts to write, test and audit; launch waits for them, or they are added after a zero-contract launch.
- A Poppie hook in the borrow and deposit path: a bug can block borrowing or deposits until it's uninstalled, which also removes its protection. Repay and liquidation are never hooked.
- Every borrow must be batched with the fee borrow (the SDK does this); direct `borrow` calls revert while a fee is set.
- More keys to secure: guardian, scheduler, denylist.
- The more Poppie can block, the more it may be expected to block.

## Still not possible

Seizing or returning funds; bounding issuer powers beyond caps; pricing borrowing and liquidation differently; liquidating a stale name; catching an attacker before they're listed; stopping the Ops Safe from changing vault settings or uninstalling the hooks.

## Unchanged

Issuers, keeper and prices, liquidity policy, hubs, Earn, rollout: as in the zero-contract design. Risk metrics: `docs/Risk-Metrics.md`.
