# Poppie v2 on Arbitrum: Overview

*Nov 16, 2026. A one-page comparison of the two candidate designs. One-pagers: `docs/zeroContracts/Overview.md`, `docs/peripheralContracts/Overview.md`. Full detail: each folder's `Design.md`.*

## What Poppie is building

USDC lending on Euler V2 (Arbitrum) against tokenized US stocks and ETFs. About 100 names at launch, growing toward 500. Lenders earn interest; borrowers post stock tokens as collateral.

Both designs reuse Poppie's audited BSC oracle unchanged and the standard Euler contracts. They differ in one choice:

- **Zero-contract:** Poppie writes no new contracts. Risk is controlled by limits set in advance, Euler's built-in controls and off-chain policy.
- **Peripheral-contract:** Poppie adds five small contracts around the same core. These enforce on-chain several limits that the zero-contract design can only promise.

## At a glance

| | Zero-contract | Peripheral-contract |
| --- | --- | --- |
| New code to audit | None | About 5 contracts, roughly 100–300 lines each (estimate) |
| Time to launch | Sooner | Later by the build and audit time, unless the contracts are added after launch |
| Can Poppie code block borrowing? | No | Yes, if a contract has a bug, until it is removed |
| Integrators | Call Euler directly | Must batch each borrow with the fee (Poppie's SDK does this) |
| Keys to secure | Fewer | Adds guardian, scheduler and denylist keys (each can only tighten) |
| Largest unbounded risk | A compromised oracle admin can set any price instantly | Bounded: small fixes instant, large moves delayed |
| Main appeal | Simple, cheap, fast | Stronger, enforceable risk controls |

## Risk management: who bounds each risk better

| ID | Risk | Zero-contract | Peripheral-contract | Better |
| --- | --- | --- | --- | --- |
| G1 | **Fast loss** (fake collateral, bad price, stolen issuer key) | Borrow caps kept just above current borrows and raised daily | An hourly borrow limit per hub | Peripheral |
| G2 | **Response speed** | Emergency key freezes caps or LTVs in seconds | Same, plus renewable pauses per hub and per asset | Similar |
| G3 | **Oracle admin compromised** | Unbounded, or every fix delayed | Small moves instant, large ones delayed | **Peripheral** |
| G4 | **Price keeper key stolen** | Can wipe every price | Can wipe at most N prices per budget window | Peripheral |
| G5 | **Ops multisig compromised** | Optional delay on loosening changes | Same | Equal |
| G6 | **Price route overwritten** | All route changes instant, or all delayed (listings too) | Listings instant, overwrites delayed | Peripheral |
| G7 | **Sanctioned or stolen funds** | Screened only in Poppie's app and SDK | Blocked on-chain, including direct callers, except deposits routed through Earn vaults | Peripheral |
| G8 | **Issuer maintenance windows** | Blocked only in Poppie's app and SDK | Enforced on-chain | Peripheral |
| G9 | **Origination fee** | Only charged through Poppie's app and SDK | Charged on every borrow | Peripheral |
| G10 | **Flash loans** | On or off | On, off or paused (no flash fee) | Peripheral |
| G11 | **One account too large** | Alert only | Optional per-account cap (easy to dodge) | Marginal |
| G12 | **Cap upkeep** | Borrow caps raised daily by an automated, bounded key; users can hit "cap reached" on busy days | No daily raises; large borrows may wait for the next hour | Peripheral |

**Why limits set in advance matter.** In April 2026 an attacker forged about $292M of a bridged token and borrowed about $230M from Aave against it within minutes. A multisig takes minutes to hours to sign. So in both designs the real bound on a loss is the caps and limits already in place, not how fast the team reacts.

**Neither design can:**

- seize, freeze or return stolen funds;
- stop an issuer from minting, burning or changing a token, beyond capping exposure to it;
- liquidate a position while its stock market is closed, or create buyers for seized collateral;
- block an attacker before they appear on a sanctions list;
- stop the ops multisig changing vault settings (a timelock only delays it).

## Costs

| | Zero-contract | Peripheral-contract |
| --- | --- | --- |
| Contract audit | None (oracle and adapter already audited) | About 5 small contracts plus their Euler integration; cost not yet estimated (POP-17) |
| Engineering | Deployment scripts, keeper, monitoring | The same, plus writing and testing 5 contracts; estimate: POP-17 |
| Launch delay | None | Estimate: POP-17; none if contracts are added after launch |
| Running cost | Keeper about 0.00009 ETH per run at today's gas (71 names) | Slightly more gas per borrow, deposit and price push |
| Operations | Daily automated cap raises; large oracle fixes need the full oracle multisig | No daily raises; small oracle fixes instant; more keys to hold |

## Recommendation

**Launch with the zero-contract design, then add peripheral contracts one at a time as each passes audit.** Each contract can be added on its own and plugs into the core without changing it. Order by risk removed:

1. **P3 oracle admin guard:** bounds the largest unbounded risk (G3).
2. **P1 hub guard:** hourly borrow limit, pauses, sanctions and fee (G1, G7, G9).
3. **P4 keeper forwarder, P5 router governor, P2 escrow guard** (G4, G6, G8).

## Risks shared by both designs

1. **No issuer has a usable market on Arbitrum yet.** xStocks (Backed) is the only launch candidate. Its only exit is Backed's own inventory: up to $1M per trade on major names in market hours, about $10k on smaller names overnight, and nothing at weekends. Poppie runs no liquidator; third parties must step in. Exposure is limited by capping each name to the exit that exists.
2. **Price coverage.** Chainlink covers 71 xStocks names on Arbitrum, below the ~100 planned for launch. No second price source quotes overnight, so names are not priced (and cannot be borrowed against or liquidated) overnight until one does.
3. **Issuer keys.** Single issuer keys can change a token's share multiplier instantly, and Robinhood's can burn tokens from any holder. This has gone wrong: HONx was halved for 8 h 25 min, and a SOXX split was applied a day early. Poppie's price keeper blocks unexplained changes; per-issuer caps limit the rest.
4. **Corporate actions.** Mergers and delistings require winding a name down before the issuer's deadline.

Open items: tracked in Linear, project Euler v2 (Poppie).
