# Poppie v2 on Arbitrum: Overview (zero-contract design)

*Nov 16, 2026. Full detail: `docs/Overview.md` (shared plan) and `docs/zeroContracts/Poppie-Arbitrum-Hub-Architecture-Governance-Plan.md` (this design). The alternative with small Poppie contracts: `docs/peripheralContracts/Overview.md`; comparison: `docs/Design-Comparison.md`.*

## What it is

USDC lending on Euler V2 (Arbitrum) against tokenized US stocks and ETFs from several issuers. About 100 names at launch, growing toward 500.

## Structure

- **No new contracts.** The BSC oracle and adapter are redeployed unchanged (already audited). Everything else is standard Euler (EVK vaults, router, Earn, and optionally Euler's emergency governor and cap steward) plus Safe multisigs.
- **Hubs (USDC pools):**
  - **Prime:** blue chips only.
  - **Three risk bands (M1–M3):** each holds all blue chips plus its band's long-tail names.
- **Lenders** deposit into two Earn vaults (Prime, Yield), which allocate across the hubs.
- **Borrowers** post stock tokens into one escrow per asset and borrow USDC from a hub.
- **Limits:**

  | | Max borrow / liquidation LTV | Max liquidation discount |
  | --- | --- | --- |
  | Prime | 70% / 75% | 8% |
  | M1 | 50% / 58% | 10% |
  | M2 | 45% / 52% | 15% |
  | M3 | 35% / 42% | 20% |

- **Revenue:** an interest fee (10–25%) and a rate floor per hub, plus Earn fees. Part funds a loss reserve.

## Control

| Who | Controls | Bounded by |
| --- | --- | --- |
| Keeper key | Price pushes, asset pauses | The oracle's per-push and per-window limits |
| Emergency key | Lower caps, lower borrow LTVs, disable a vault | Euler's emergency governor: tighten only |
| Cap steward key | Routine cap changes | Euler's cap steward: a bounded factor per interval |
| Oracle Safe | Prices and oracle settings | Nothing, unless every admin action is put behind a timelock |
| Ops Safe | Hubs, LTVs, caps, listings, routes | Its signers; optionally a timelock of at least a day on loosening changes |
| Reserve Safe | Repays bad debt | Its signers |

## Risk management

**What bounds a loss** is what is set in advance, because an attack can borrow in minutes and a Safe takes longer to sign:

- supply caps per name and per issuer, sized to exit depth;
- borrow caps kept a set headroom above current borrows and raised daily within bounds, so a fast attack can borrow at most that headroom;
- LTV buffers and liquidation discounts sized for weekend gaps;
- the keeper's blocking price and multiplier checks;
- a loss reserve.

**How we restrict capital fast:** an emergency key can freeze caps or lower borrow LTVs in seconds. Repay and liquidation always stay open. The keeper can stop pricing a name, at the cost of wiping its price.

**What we can't do without contracts:**

- freeze, seize or return one account's funds;
- limit borrowing per hour except by keeping caps tight;
- bound a compromised Oracle Safe without delaying every price fix;
- stop a stolen keeper key from wiping every price;
- list instantly while delaying route overwrites;
- block sanctioned addresses that call the contracts directly (the issuer tokens and USDC block their own listed addresses);
- enforce the origination fee (the SDK charges it) or issuer pause windows (the app blocks them).

**What not writing contracts saves:** no new audit; no Poppie code in the borrow path that could block borrowing; integrators call Euler directly; less gas; fewer keys; a faster launch. Any peripheral contract can be added later without touching the core.

## Prices

- **Source:** a keeper, extended from the one running on BSC, pushes one price per asset every 30 minutes. That price is used for both borrowing and liquidation.
- **Calculation:** Chainlink Data Streams stock price × the issuer's multiplier, read on-chain.
- **Blocking checks before every push:**
  - the stock price must agree with an independent second source;
  - the multiplier must match the issuer's published value and a real corporate action.

  On a failure the name is skipped and an alert fires. This catches errors like the HONx multiplier halving.
- **Status:** a prototype of this keeper passes split, rogue-multiplier, pause, outage and scale tests on an Arbitrum fork against the real xStocks contracts.
- **Coverage limit:** Chainlink Data Streams covers 71 xStocks names on Arbitrum, below the ~100 planned for launch. Whether phase 1 waits for more coverage or launches with fewer names is still to decide.
- **Oracle limits:** each push and the drift per window are bounded; anything larger needs the Oracle Safe.
- **Closed markets:** with no good price, the price goes stale after one hour. Borrowing, withdrawals and liquidations then stop for accounts holding that name.

## Issuers

| Issuer | Status |
| --- | --- |
| xStocks (Backed) | Contracts fit. Exit is Backed's own inventory only, with nothing at weekends. **Main launch candidate** |
| Robinhood | Contracts fit. Not on Arbitrum yet |
| Reality | Contracts fit. Supply concentrated, small pools, unverified code. **Not now** |
| Dinari | The issuer can pull wrapper backing. **Blocked** |
| Ondo | Not on Arbitrum |

We only take issuers whose dividends are reinvested, and we will not onboard directly with any issuer (legal).

## Main risk: thin liquidity and liquidations

- **The problem:** on Arbitrum, exit liquidity for these tokens is mostly the issuer's own inventory: up to $1M per trade on major xStocks names in market hours, around $10k on long-tail names overnight, and none at weekends. No one is committed to buy seized collateral, and Poppie runs no liquidator at launch.
- **Who liquidates:** third parties. They can sell seized collateral atomically through Enso (Backed has allowlisted Enso; 0x routes through it) or more slowly through CoW solvers.
- **How we limit exposure:**
  - **List** only names with an exit route open to third parties.
  - **Cap** each name's supply at 10–20% of its exit depth in the weakest session it's priced in.
  - **Don't price** names in sessions where the exit is too thin; the price goes stale instead, which also pauses liquidations.
  - **Set LTV buffers and discounts** to cover weekend gaps and the cost of holding seized stock.
  - **Limit concentration** per hub, per issuer and per stock.
  - **Absorb bad debt** from the loss reserve.
  - **Alert** when positions stay liquidatable, when an exit route disappears, or when bad debt appears.
- **Deferred:** a Poppie-run liquidator. Revisit if third parties don't act at launch sizes.

## Other risks

- **Issuer keys:**
  - single keys at xStocks and Robinhood can change multipliers instantly;
  - Robinhood keys can burn tokens from any holder.

  Defended by the keeper's checks and per-issuer caps.
- **Corporate actions:**
  - splits and dividends run through the multiplier, automatically;
  - mergers and delistings require winding the name down before the issuer's deadline.
- **Ops Safe:** it holds all structural power with no notice period. It reviews every change decoded and simulated, but signing fatigue is a real risk.

## Open items

1. An issuer with a usable Arbitrum market. xStocks is the only candidate today.
2. Confirm third parties can liquidate xStocks through Enso at our cap sizes, and choose the second price-source vendors.
3. Price coverage beyond 71 names: more Chainlink feeds or a second primary source.
4. A corporate-action data feed (splits and dividends, net of withholding). The keeper's multiplier check depends on it: without it, every dividend stops that name's pricing until someone adds it by hand.
5. Fork tests on Euler: stale-price behaviour, caps, and Earn accepting the hubs.

## Rollout

| Phase | Scope | Gate |
| --- | --- | --- |
| 0 | Extended keeper; Euler and liquidation fork tests | Tests pass; issuer questions answered |
| 1 | About 100 names: Prime plus 3 band hubs, 2 Earn vaults | Config check passes; alerts live |
| 2 | Toward 500 names | — |
