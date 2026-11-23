# Issuers on Arbitrum at a glance

*Nov 5, 2026 (UTC); updated Nov 16. Poppie will not onboard directly with any issuer and runs no liquidator at launch; third parties liquidate through providers the issuer already allows, and caps limit exposure to the exit that exists (D9). Details and evidence (finding IDs in brackets): `xStocks.md`, `Robinhood.md`, `Reality.md` and `Dinari-Ondo.md` in this folder. Liquidity policy and corporate actions: `docs/zeroContracts/Design.md`.*

| | xStocks (Backed) | Robinhood Stock Tokens | Dinari | Ondo GM | Reality |
| --- | --- | --- | --- | --- | --- |
| **On Arbitrum** | Yes, ~1,490 names | No; Robinhood Chain only, Arbitrum expected [RH-11] | Yes, 251 names | No [ON-1] | Yes, 3,334 tokens (1,178 with supply) [RE-11] |
| **Fits v1 contracts unchanged** | Yes, via issuer V2 wrapper [XS-1, XS-2] | Yes, no wrapper needed [RH-1, RH-2] | Not as is | — | Yes, no wrapper needed (since 2026-10-17) [RE-1] |
| **Splits, dividends** | Multiplier; wrapper follows; reinvested | Multiplier on static balances (ERC-8056); reinvested | Rebase; wrapper rate moves with donations [DN-3] | Reinvested, static balances | Multiplier on static balances (ERC-8056), applied at once; **rebased before 2026-10-17** [RE-3]; dividends (cash in USDT0, stock in rTokens) paid separately to the depositor via Merkl; **withheld for Poppie escrows until Merkl supports them** [RE-9] |
| **Fork-tested** | Yes (Arbitrum) | Yes (Robinhood Chain) | No | — | Yes (Arbitrum) |
| **Exit liquidity** | Backed's inventory only, via its allowlisted RFQ (`AtomicSwap`): $1M/trade majors in market hours, $10k long tail overnight, none at weekends. Reached through Enso, 0x (via Enso) or CoW solvers [XS-7] | Out of scope (not on Arbitrum) | Thin, concentrated [DN-5] | — | **97–100% in 2–3 EOAs; four ~$190k Uniswap pools**; atomic USDC redemption only for wallets Reality registers [RE-10] |
| **Atomic liquidation** | Possible for third parties through Enso, which Backed has allowlisted [D9] | — | — | — | Uniswap pools only. Atomic redemption needs Reality to register the liquidator, which is ruled out [RE-10, D9] |
| **Issuer can take collateral** | No burn from holders | **Yes: two EOAs can burn from any holder** [RH-5] | **Yes: `recover` moves wrapper backing** [DN-2] | — | No burn found; freeze and pause can lock it [RE-6] |
| **Multiplier key** | One EOA, unbounded; notice 4 min to 4 h [XS-4, XS-9] | One EOA, unbounded, instant [RH-4] | Admin unconfirmed [DN-4] | — | Registry action (EOA) + 3-of-5 Safe executes; ratio hash-checked; can run early [RE-2] |
| **Known incidents** | HONx halved for 8 h 25 min, 2026-06-29 [XS-13] | SOXX 3:1 split applied a day early (2026-11-04), reverted, re-applied 11-05 [RH-6, RE-5] | — | — | rCRWD split a week early and reversed; rHON reverse split applied twice (2026-06-29); splits left unexecuted (rMTUM, rQUAL and 6 older); SOXX applied 6 h before the open [RE-4, RE-5] |
| **Mergers, delistings** | Wrapper holders must unwrap first; none completed yet; KVUEx pending [XS-8, XS-12] | Not active; undocumented [RH-9] | — | — | 4 delisted, balances left, no payout seen; process unknown [RE-11, RE-12] |
| **Upgrades, admin** | 2-of-3 Safe, no timelock | EOAs on one registry for all tokens [RH-8] | EOA owns beacons [DN-4] | — | One beacon for all tokens, 3-of-5 Safe, no timelock; **source unverified** [RE-7] |
| **Verdict** | **Listable, with caps sized to Backed's quoted depth per session** | **Good design; wait for Arbitrum; issuer risk accepted** | **Blocked** (`recover`) | **Unavailable** | **Not now** (liquidity, issuer record, unverified code) [D10] |

Open items: tracked in Linear, project Euler v2 (Poppie).

## Reality dividends in an escrow

From Reality's docs (Dividends & Claiming), which we take at their word:

- **How they're paid:** cash dividends in stablecoins (USDT0) and stock dividends in rTokens, paid separately. They never go into the token price or the multiplier.
- **Who gets them:** the holder at the record date. For rTokens deposited in DeFi, the dividend belongs to the depositor. Merkl snapshots balances in *supported* protocols and traces each one back to its owner. Reality then sends the dividend to that owner's wallet, and the claim contract pays only the owner in the snapshot.
- **Unsupported protocols:** the dividend is "held, not forfeited". It is released once Merkl adds the protocol.

For Poppie, with no Merkl relationship (the default):

- **Depositors' dividends are withheld by Reality.** They don't arrive at the escrow, nothing gets stuck, and no new contract is needed.
- **Released if Merkl adds Poppie's escrows,** paid to the depositors. We can't verify how long Reality keeps them in the meantime.
- **The collateral price still drops on the ex-date,** so depositors are worse off until then. This needs disclosure.
- **Owed to depositors, not to the escrow.** Merkl traces each balance through a supported protocol to the owner of the position: for Poppie, the owner of the Euler sub-account holding the escrow shares. That owner may be an EOA, a Safe or a smart wallet. Withheld dividends would be back-paid to whoever owned each position at each record date, so the escrow never needs to claim anything.
- **Not protocol revenue in either case.** The dividends belong to depositors, and a wrapper to capture them would go against Reality's stated policy, so we dropped the idea.

**Merkl support** (optional; POP-72): Merkl already lists Euler and EulerEarn as protocols, but we found no public sign of Reality snapshots covering them. Details: RE-9.

## Applies to every issuer

- The keeper must apply only multiplier changes that match a known corporate action. The HONx, SOXX and rHON errors would otherwise reach the price; Reality's double rHON step is an exact −50% push, which a 5000 bps breaker allows.
- Corporate-action responses must be automated: issuer notice can be under 15 minutes (xStocks), and Reality can execute a split before its effective time. Both are too fast for a Safe.
- Cap exposure per issuer: one key set covers every token from that issuer.
