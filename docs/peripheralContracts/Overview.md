# Peripheral-contract design: Overview

*Nov 16, 2026. Comparison with the alternative: `docs/Overview.md`. Full detail: `docs/peripheralContracts/Design.md`.*

*Status, Nov 17, 2026: P1–P5 are implemented, with unit, invariant and fork tests (mock EVK; 5 fork tests at pinned Arbitrum block 525105000). EVK integration is unverified and the contracts are not audited.*

## What it is

The zero-contract design (same hubs, issuers, price keeper and liquidity policy) **plus five small Poppie contracts**. They plug into slots the existing contracts already expose, so the audited oracle and the Euler contracts stay unchanged. Each contract is optional, holds no funds, and can be removed.

| Contract | What it adds |
| --- | --- |
| P1 hub guard | Hourly borrow limit; renewable pause; sanctions blocking; enforced origination fee |
| P2 escrow guard | Issuer maintenance windows and sanctions enforced on-chain; optional account freeze |
| P3 oracle admin guard | Small price fixes instant, large ones delayed or second-approved |
| P4 keeper forwarder | Several keeper keys; a cap, per configurable window, on how many prices the keepers can pause |
| P5 router governor | New listings instant; changes to existing price routes delayed |

## How risk is controlled

| Who | Can do | Limited by |
| --- | --- | --- |
| Price keepers (automated) | Push prices; pause up to N names per configurable window | Oracle move limits; P4 |
| Guardian key (on call) | Pause borrowing and deposits; cancel queued oracle changes; revoke keepers | Can only tighten |
| Emergency and cap steward keys | As in the zero-contract design | Euler |
| Oracle multisig | Prices and oracle settings | ±X% of a per-window reference instant; larger moves delayed or second-approved after queuing (P3) |
| Ops multisig | Hubs, LTVs, caps, listings | Its signers; route overwrites delayed (P5); can remove the hooks |

**What bounds a loss:** an hourly borrow limit per hub, plus the same caps, LTV buffers, price checks and loss reserve as the zero-contract design. Repay and liquidation are never blocked by a Poppie contract.

## Pros

- **A compromised oracle multisig is bounded**, while small fixes stay instant.
- **Fast attacks are capped per hour**, without daily cap raises or "cap reached" errors.
- A stolen keeper key can't wipe every price.
- Sanctions, the origination fee and issuer maintenance windows are enforced on-chain, for direct callers too. Sanctions apply to direct hub and escrow deposits; Earn depositors aren't screened by P1.
- An account freeze is available if counsel requires one.

## Cons

- About five contracts to write, test and audit.
- A bug in a Poppie hook can block borrowing or deposits until the hook is removed, which also removes its protection.
- Every borrow must be batched with the fee (the SDK does this).
- More keys to secure.
- The more Poppie can block, the more it may be expected to block (court orders, regulators).

## Costs

| Item | Estimate |
| --- | --- |
| New contract audit | About 5 contracts of roughly 100–300 lines, plus their Euler integration; cost not yet estimated (POP-17) |
| Engineering | Zero-contract work plus the 5 contracts; estimate: POP-89 |
| Launch delay | Estimate: POP-89; none if the contracts are added after a zero-contract launch |
| Running cost | Slightly more gas per borrow, deposit and price push |

## Still not possible

Seizing or returning funds; limiting issuer powers beyond caps; liquidating a name while its market is closed; catching an attacker before they're listed; stopping the ops multisig from changing vault settings or removing the hooks.

Open items: tracked in Linear, project Euler v2 (Poppie).
