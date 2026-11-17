# Zero-contract design: Overview

*Nov 16, 2026. Comparison with the alternative: `docs/Overview.md`. Full detail: `docs/zeroContracts/Design.md`.*

## What it is

USDC lending on Euler V2 (Arbitrum) against tokenized US stocks and ETFs. **Poppie writes no new contracts.** It redeploys its audited BSC price oracle unchanged and uses standard Euler and Safe contracts. Lenders deposit into two pooled vaults (Prime and Yield), which lend through four hubs: one for blue chips, and three for riskier names by risk band.

## How risk is controlled

| Who | Can do | Limited by |
| --- | --- | --- |
| Price keeper (automated) | Push prices; pause a name's price | The oracle's per-update and per-day move limits |
| Emergency key (on call) | Lower caps and LTVs, or freeze a vault, in seconds | Euler: can only tighten |
| Cap steward key (automated) | Routine cap changes | Euler: a bounded step per interval |
| Oracle multisig | Any price or oracle setting | **Nothing**, unless every action is put behind a delay |
| Ops multisig | Hubs, LTVs, caps, listings | Its signers; optionally a 1-day delay on loosening |

**What bounds a loss** is set in advance: supply caps per name and per issuer sized to exit liquidity; borrow caps kept just above current borrowing and raised daily; LTV buffers sized for weekend gaps; blocking price checks; and a loss reserve. Repay and liquidation always stay open.

## Pros

- No new code to audit; launches sooner.
- No Poppie code in the borrowing path, so a Poppie bug can't block users.
- Integrators call Euler directly.
- Fewer keys and settings to secure.
- Any peripheral contract can be added later without touching the core.

## Cons

- **A compromised oracle multisig can set any price instantly**, unless every fix is delayed. This is the largest unbounded risk.
- A stolen price keeper key can wipe every price.
- Borrowing bursts are limited only by keeping caps tight, which means daily cap raises and "cap reached" errors on busy days.
- Sanctions screening, the origination fee and issuer maintenance windows are enforced only in Poppie's app; direct callers bypass them.
- No way to freeze, seize or return one account's funds.

## Costs

| Item | Estimate |
| --- | --- |
| New contract audit | None |
| Engineering | Deployment scripts, keeper extension (prototyped), monitoring: **TBD** |
| Running cost | Keeper about 0.00009 ETH per run (71 names) |
| Operations | Daily cap raises; an on-call rota for oracle fixes |

## Main risks

1. **Thin exit liquidity.** The only buyer for xStocks on Arbitrum is Backed's own inventory: up to $1M per trade on majors in market hours, about $10k on smaller names overnight, none at weekends. Third parties liquidate; Poppie runs no liquidator. Each name is capped at 10–20% of its exit depth.
2. **Issuer keys** can change multipliers instantly (and at Robinhood, burn tokens). The keeper blocks unexplained changes; per-issuer caps limit the rest.
3. **Ops multisig** holds all structural power with no notice period, and signs often, so fatigue is a risk.

## Open items

1. An issuer with a usable Arbitrum market (xStocks is the only candidate).
2. Confirm third parties can liquidate through Enso at our cap sizes.
3. Price coverage beyond Chainlink's 71 names.
4. A corporate-action data feed; without it, every dividend stops that name's pricing until added by hand.
5. Set the risk appetite (loss limits, reserve size).

## Rollout

| Phase | Scope | Gate |
| --- | --- | --- |
| 0 | Extended keeper; Euler and liquidation fork tests | Tests pass; issuer questions answered |
| 1 | About 100 names: 4 hubs, 2 lender vaults | Config check passes; alerts live |
| 2 | Toward 500 names | — |
