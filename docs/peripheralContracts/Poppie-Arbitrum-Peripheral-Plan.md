# Poppie on Arbitrum: Hub Architecture & Governance Plan (peripheral-contract design)

*This is the **peripheral-contract design**: the audited v1 oracle and adapter and every stock Euler contract are used unchanged, and five small Poppie contracts sit in slots those contracts already expose (vault hooks, the oracle's `admin` and `keeper` slots, the router's governor). Risk management is its primary goal; see "Risk management" for the risks, the levers, what this design buys and costs over the zero-contract design, and what it still cannot do. Zero-contract plan: `docs/zeroContracts/Poppie-Arbitrum-Hub-Architecture-Governance-Plan.md`. Comparison: `docs/Design-Comparison.md`. Contract specifications: `docs/peripheralContracts/Peripheral-Contracts.md`. Risk metrics: `docs/Risk-Metrics.md`. Sections shared by both designs are in `docs/Overview.md`.*

## TL;DR

Poppie lends USDC on Euler V2 against tokenized equities, from about 100 assets at launch toward 500.

- **Contracts:** Poppie's existing `PoppieEulerOracle` and `PoppieEulerAdapter` (tag `v1-bsc`) are redeployed unchanged. Everything else is stock:
  - Euler: EVK, EulerRouter, Earn, and Euler's governance contracts (`GovernorAccessControlEmergency`, `CapRiskSteward`, optionally timelocks);
  - Safe and OpenZeppelin `TimelockController`.

  **Plus five small Poppie peripheral contracts** (P1–P5, new audit scope): a hub guard and an escrow guard (vault hooks), an oracle admin guard, a keeper forwarder and an add-only router governor. Each is optional and independent.
- **Hubs:** one Prime hub (blue chips only) plus one hub per long-tail risk band. Each band hub holds all blue chips and that band's long-tail names.
- **Lenders:** deposit USDC into Prime Earn or Yield Earn, which allocate across the hubs.
- **Revenue:** interest fee and rate floor per hub, plus Earn performance fees. Part of Poppie's share funds a loss reserve.
- **Prices:** a keeper, extended from the BSC keeper, pushes one USD price per asset, used for both borrowing and liquidation. The oracle bounds each push and the drift per window. Before pushing, the keeper checks the stock price against an independent source and the multiplier against the issuer, and skips the name on a mismatch (D11).
- **Closed markets:** one rule. Push whenever a reliable price exists; otherwise let the price go stale, which freezes affected accounts until reopen.
- **Control:** the Oracle Safe acts on the oracle through the oracle admin guard (P3): small price moves instant, large ones delayed or second-approved. Keepers push through the keeper forwarder (P4). `MS_OPS` governs vaults through Euler's emergency governor (D12) and adds routes through the router governor (P5). Hot keys can only tighten: guardian, emergency, scheduler and denylist keys.
- **Risk:** losses are bounded by limits set in advance: supply caps per name and issuer, an hourly borrow limit per hub (P1), LTV buffers and the loss reserve. Over the zero-contract design, this bounds a compromised Oracle Safe and a stolen keeper key, enforces sanctions screening, the origination fee and issuer pause windows on direct calls, and keeps listings instant while delaying route overwrites. It costs new audit scope and a Poppie hook in the borrow path (see "Risk management").
- **Issuers:** only tokens whose dividends are reinvested. Rebasing tokens enter through the issuer's non-rebasing wrapper, and the **wrapper share** is the priced asset. Tokens with static balances and a multiplier (ERC-8056, e.g. Robinhood) are held and priced directly.
- **Main open risk:** no issuer has a listable market on Arbitrum today. xStocks' contracts fit this design (tested on an Arbitrum fork), but nearly all supply is Backed inventory and there are no DEX pools. The only exit is Backed's inventory via its allowlisted `AtomicSwap`. Backed quotes up to $1M per trade on majors in market hours and $10k on long-tail names overnight, with nothing executable at weekends. Backed will not liquidate itself. Poppie will not onboard with any issuer and runs no liquidator at launch. Third parties can sell through Enso, which Backed already allowlists, and the plan caps exposure to the exit that exists (D9). Dinari's wrapper lets the issuer remove backing. Ondo is not deployed. Robinhood Stock Tokens fit with no wrapper (tested on a Robinhood Chain fork) but are not yet on Arbitrum, and Robinhood keys can burn from any holder. Reality's rTokens are on Arbitrum and fit with no wrapper (tested on a fork), but 97–100% of supply sits in two or three EOAs, their contracts are unverified, and their corporate-action record has errors (D10).
- **Price coverage:** Chainlink Data Streams covers 71 of the 1,488 xStocks names on Arbitrum, below the ~100 planned for launch. More names need more Chainlink feeds or a second primary source (KEEP-4).

| Choice | Gain | Cost |
| --- | --- | --- |
| Reuse the existing oracle | No new oracle code to audit | One price for borrowing and liquidation; pause wipes price state; one admin and one keeper address |
| Stock Euler contracts, governed by a Safe through Euler's emergency governor | Instant tightening by a hot key; bounded cap raises without signing | Users trust `MS_OPS`'s signers; it can uninstall Poppie's hooks |
| Five small Poppie peripheral contracts | Hourly borrow limit; bounded oracle admin; keeper pause budget; on-chain sanctions screening, fee and pause windows; add-only routes | New audit scope; a Poppie hook in the borrow and deposit path; more keys; every borrow must be batched |
| One hub per band | Deep liquidity, simple config | Lenders in a hub share every name's risk |
| Reinvesting issuers only | No dividend handling | Smaller listable set |

Euler allows at most 10 collaterals per account, so large portfolios need several sub-accounts. All numbers are proposed starting values.

## How to read the controls in this plan

| Label | Meaning |
| --- | --- |
| **[v1]** | Enforced by `PoppieEulerOracle` or `PoppieEulerAdapter` |
| **[Euler]** | Enforced by stock Euler code (EVK, EulerRouter, evk-periphery, Earn) |
| **[Poppie]** | Enforced by a Poppie peripheral contract (P1–P5). New code, to be audited; removable by its governor |
| **[Safe]** | Enforced only by a Safe's signer threshold |
| **[Policy]** | Enforced only by Poppie's back end or runbooks. Not visible to or enforceable by the chain |

Anything labelled **[Policy]** is a promise, not a guarantee, and must be published as such.

Three Safes are used:

- **Oracle Safe**: holds the oracle admin.
- **`MS_OPS`**: 3-of-5; governs the hubs, escrows, router, adapter and Earn.
- **Reserve Safe**: holds the loss reserve.

## Risk management

Risk management is the primary goal of this design. This chapter lists what can go wrong, which levers bound each risk, how fast each lever acts and who holds it, and what this design still cannot do. Metrics (R1–R10): `docs/Risk-Metrics.md`. Gap-by-gap comparison with the zero-contract design: `docs/Design-Comparison.md`. Contract specifications: `docs/peripheralContracts/Peripheral-Contracts.md`.

### Principles

1. **Losses are bounded by what is set in advance, not by how fast we react.** The Kelp/Aave attacker borrowed about $230M within minutes; a Safe takes minutes to hours to sign. Here the hourly borrow limit (P1) bounds a burst without keeping caps tight, and caps and LTVs bound the rest.
2. **Tightening is fast; loosening is slow.** Keys that can only tighten may be hot and act in seconds. Anything that raises exposure needs `MS_OPS`, a bounded steward, or a delay.
3. **Repay and liquidation stay open.** No Poppie contract hooks repay or liquidation, and seizure transfers always pass. Only Euler's vault-wide disable stops them.
4. **Every Poppie contract can be removed.** `MS_OPS` can uninstall a hook; each slot contract has a delayed exit back to a Safe. A contract bug costs its protection, never user funds: no Poppie contract holds or moves funds.
5. **Anything labelled [Policy] is a promise, not a guarantee.**

### Risk appetite

Set by Poppie, not yet set: `L_issuer`, `L_event`, `C_account`, `T_freeze` (`docs/Risk-Metrics.md`). In this design `L_event` sets the hub guard's hourly borrow limit; caps can be sized to exit depth alone.

### Risk register

| Risk | Levers in this design | What bounds the loss | What remains | Change from zero-contract |
| --- | --- | --- | --- | --- |
| **Unbacked or forged collateral** (stolen issuer minter key, issuer upgrade, bridged token) | No bridged tokens **[Policy]**; supply caps per name and issuer (R1) **[Euler]**; hourly borrow limit per hub (R2) **[Poppie]**; guardian pause on borrows and deposits **[Poppie]**; emergency key **[Euler]** | The smaller of R1 and the borrow limit × time to pause | Up to that bound; the reserve covers it (R3) | Rate limit replaces tight cap headroom; no daily cap raises needed |
| **Wrong price within the oracle's bounds** | Keeper gates (D11) **[Policy]**; breaker and cumulative cap **[v1]**; hourly borrow limit **[Poppie]**; guardian pause | Breaker per name; borrow limit across hubs | A wrong price inside the breaker goes live until the next push or a pause | Same, with the rate limit as the hub-wide bound |
| **Issuer multiplier error** | Keeper's multiplier gate (KEEP-11) **[Policy]** | Price stays at the last good value | Wrapper balances reflect the error | Same |
| **Oracle Safe compromised** | Oracle admin guard (P3): moves within ±X% instant, larger ones delayed or second-approved, all cancellable **[Poppie]** | ±X% per instant call; anything larger visible for the delay | Repeated small moves, each alerted; the guardian cancels | **Bounded**, where the zero-contract design is unbounded or fully delayed |
| **Keeper key stolen** | Keeper forwarder (P4): several keys, a daily pause budget, instant revocation by a guardian **[Poppie]**; breaker **[v1]** | Breaker per push; at most N assets paused per day | N prices wiped before revocation | Can no longer wipe every price |
| **`MS_OPS` compromised** | Euler's emergency governor (D12), optional timelocks; add-only router governor (P5): listings instant, overwrites delayed **[Poppie]** | Route overwrites visible for the delay | Without a timelock on vault governance, LTVs and hooks change instantly; it can uninstall Poppie's hooks | Router overwrites delayed without delaying listings |
| **Liquidations fail** | Caps sized to exit depth, buffers, discounts, session gating, reserve **[Policy]** | R5 per name | Bad debt above the reserve | Same |
| **Gap through the breaker** | Stale freeze; LTV buffers; `adminSetPrice` through P3 (instant within ±X%, else delayed or second-approved) | LTV buffer | Large gap corrections wait for the delay or the second Safe | Large corrections slower, small ones as fast |
| **Issuer burns from, freezes or pauses an escrow** | Per-issuer caps; alerts; escrow guard enforces published pause windows (P2) **[Poppie]** | R1 for that issuer | Escrow cash overstated after a burn | Pause windows enforced on-chain |
| **Stolen funds or sanctioned users** | Hub and escrow guards screen borrowers, receivers and depositors against Chainalysis's list and Poppie's denylist **[Poppie]**; issuer and USDC lists; optional account freeze (P2, legal decision) | Listed addresses blocked from new positions, also on direct calls | New attackers before listing; fresh addresses; funds can't be seized or returned | **Enforced on-chain**, not just in the app |
| **Lender run** | Kink IRM; Earn allocation; utilization alerts; lender-deposit screening | Utilization above the kink | — | Same |
| **USDC depeg or blacklist of a hub** | Alerts; guardian pause | — | Fixed-rate route; frozen USDC | Same |
| **Sequencer outage** | Keeper grace (KEEP-17) | — | — | Same |
| **Bug in Euler, Safe or the v1 contracts** | Audits; caps; rate limit | R1, borrow limit | Outside Poppie's control | Same |
| **Bug in a Poppie peripheral contract** (new) | Audit; rules (no custody, never hook repay or liquidation); `MS_OPS` uninstalls a hook; slot contracts have a delayed exit | A bug can block borrowing, deposits, pushes or admin calls until removed | Loss of that contract's protection while removed | **New risk** |

### Levers to restrict capital

Everything in the zero-contract design (emergency key, cap steward, `pauseAssets`, LTV ramps, Earn allocation) stays. This design adds:

| Lever | Contract | Who holds it | Speed | Stops | Leaves working |
| --- | --- | --- | --- | --- | --- |
| Hourly borrow limit per hub | P1 hub guard | `MS_OPS` sets it; always on | Continuous | Bursts above the limit | Repay, liquidation, normal borrowing |
| Guardian pause of borrows and flash loans, renewable | P1 | Guardian key; `MS_OPS` unpauses | Seconds | Borrowing in a hub | Repay, liquidation, deposits |
| Guardian pause of escrow deposits | P2 escrow guard | Guardian key | Seconds | New collateral in a name | Withdraw, liquidation |
| Scheduled deposit and withdraw windows | P2 | Scheduler key (adds bounded windows only) | Scheduled | Escrow deposits and withdrawals during issuer windows | Liquidation |
| Sanctions block on borrow, receiver and deposit | P1, P2 | Denylist key; Chainalysis list | Instant once listed | Listed addresses opening positions | Their repay and liquidation |
| Account freeze (optional) | P2 | Denylist key, under policy set by counsel | Instant | A listed account's withdrawals | Its liquidation |
| Account debt cap (optional) | P1 | `MS_OPS` | Continuous | One account's debt above the cap | — |
| Bounded oracle admin | P3 | Oracle Safe; guardian cancels | ±X% instant; rest delayed | Large price writes without notice | `pauseAssets` stays instant |
| Keeper pause budget and revocation | P4 | Guardian revokes; Oracle Safe adds keys | Instant | Mass `pauseAssets` by a stolen key | Pushes by other keys |
| Add-only routes | P5 | `MS_OPS` adds; timelock overwrites | Adds instant | Route overwrites without notice | Listings |

### What this design still cannot do

- **Seize, move or return funds.** No Poppie contract can, by design.
- **Bound issuer powers:** mint, burn, multiplier, upgrades. Only caps and monitoring limit them.
- **Price borrowing and liquidation differently**, or pause a name without wiping its price (`pauseAssets` is v1 behaviour).
- **Liquidate a stale name**, or create exit liquidity.
- **Catch an attacker before they are listed**, or stop one using fresh addresses.
- **Bind `MS_OPS`** beyond the router: it can uninstall hooks and, unless vault governance is timelocked, change any vault setting instantly.
- **Stop Arbitrum's Security Council** acting on any contract.

### What it buys over the zero-contract design

- **Fast attacks are bounded by an hourly borrow limit**, so caps no longer have to sit just above borrows and be raised daily, and borrowers don't hit "cap reached" on busy days.
- **A compromised Oracle Safe is bounded.** Small corrections stay instant.
- **A stolen keeper key can't wipe every price**, and several keepers run without sharing a key or nonce.
- **Listings stay instant while route overwrites are delayed.**
- **Sanctioned addresses are blocked on-chain**, including direct callers; an account freeze is available if counsel requires it.
- **The origination fee is enforced** on every borrow.
- **Issuer pause windows are enforced on-chain.**
- **Renewable guardian pauses** of borrows and deposits, per hub and per escrow.

### What it costs

- **New audit scope:** five small contracts (about 100–250 lines each, estimated) plus their integration with EVK hooks. The 2026 audit covered only the oracle and adapter.
- **A Poppie hook in the borrow and deposit path.** A bug can block borrowing or deposits until `MS_OPS` uninstalls it, and uninstalling removes its protection. Repay and liquidation are never hooked.
- **Integration:** every borrow must be in an EVC batch with the fee borrow; a direct `borrow` reverts while a fee is set.
- **Gas:** one extra call per hooked operation and per push.
- **More keys:** guardian, scheduler, denylist; each tighten-only.
- **More to explain:** the more Poppie can block, the more it may be expected to block (sanctions, court orders).
- **Time:** contracts must be written, tested on the EVK harness and audited before launch, or added after a zero-contract launch.

### Sanctions

**On-chain, with no Poppie code (as in the zero-contract design):** xStocks tokens and wrappers check Chainalysis's list (`0x40C5…C8fb`); Robinhood's registry blocklist; Circle's USDC blacklist.

**Added by this design:**

- P1 blocks a listed or denylisted account (by EVC owner) from borrowing, and blocks borrowed USDC going to a listed receiver; it screens lender deposits into hubs.
- P2 screens collateral depositors. Optional: freeze withdrawals for a listed account, if counsel requires it; liquidation still proceeds.
- The app and SDK still screen first, to fail early with a clear message.

**Still not possible:** seizing or returning funds; blocking repay or liquidation of a listed account; catching attackers before listing; stopping fresh addresses.

Counsel should decide whether the account freeze should exist at all, and how Poppie responds to court orders and claims like the one Aave faced over the Kelp funds.

## Shared design

The following are identical in both designs and live in `docs/Overview.md`: How it works, Asset classes, Issuers (xStocks, Dinari, Robinhood, Reality), Hubs (bands, revenue, loss reserve), Thin liquidity and liquidations, Prices and closed markets (oracle bounds, keeper, price sources, closed markets, corporate actions), shared monitoring, shared decisions (D1–D4, D7, D9–D11, D18), known blockers 1–9, open gaps and shared deferred items. Below are only the parts that differ in this design.

## Flash loans and fees

Flash loans of hub USDC are on and free at launch, so third-party liquidators need no capital where the exit is atomic (a DEX pool, or a sale through Enso to Backed). P1 can turn them off, pause them, or charge a fee, set by `MS_OPS`.

- **Origination fee (enforced, D16):** every borrow pays a fee, set per hub (capped on-chain, for example at 100 bps). The batch must contain the user's `hub.borrow(amount, receiver)` and `hub.borrow(fee, feeReceiver)`; P1 records both in transient storage and the vault status check reverts the batch if the fee is short. The fee becomes part of the user's debt, so a first-time borrower needs no USDC up front, and no Poppie contract holds funds. Borrows of the full available cash are rejected. Integrators must batch every borrow; the SDK does. Liquidation, repay and withdraw pay nothing.

## Issuer pause windows [Poppie]

Issuers pause assets on-chain for scheduled operations. Example: Ondo pauses with reason `ASSET_PAUSED` for 20 minutes (00:52–01:12 UTC, weekdays) to apply its daily dividend share-multiplier update.

- **Schedule:** the back end loads each issuer's pause schedule (status API, or on-chain schedules such as xStocks' `newMultiplierActivationTime`) and serves it to the app and SDK.
- **On-chain:** the scheduler key writes each window (plus a buffer) to the escrow guard (P2), which reverts deposits and withdrawals of that name during it, for direct callers too. Liquidation seizure always passes. Windows are bounded in length and number per day; `MS_OPS` can clear them.
- **App and SDK:** disable deposit and withdraw for that name during a window, with a banner and a typed error, so users fail early.
- **Pricing:** the keeper skips pushes for that name during the window, and applies the issuer's new multiplier from its activation time.
- **No oracle pause:** the keeper doesn't pause the oracle for scheduled windows: a pause wipes the price and needs the Oracle Safe to re-seed it (PAUSE-1).
- **Notify:** an issuer pause inside a known window is logged, not paged. An unscheduled pause, or one that outlasts its window, pages on-call (see Monitoring, here and in `docs/Overview.md`).

## Contracts Poppie deploys on Arbitrum

Five Poppie peripheral contracts are deployed (P1–P5). They are new, immutable and to be audited; specifications in `docs/peripheralContracts/Peripheral-Contracts.md`. Euler's governance contracts are used as published at the `evk-periphery` pin; their audit coverage at that pin is to confirm.

| Contract | Code | Count | Controlled by |
| --- | --- | --- | --- |
| `PoppieEulerOracle` | Existing, audited | 1 | `admin`: P3. `keeper`: P4 |
| `PoppieEulerAdapter` | Existing, audited | 1 | `admin`: `MS_OPS` |
| USDC/USD fixed-rate oracle | Euler `FixedRateOracle` | 1 | Immutable |
| EulerRouter | Euler | 1 | Governor: P5 |
| Kink IRMs | Euler IRM factory | 1 per band, plus Prime | Set by `MS_OPS` |
| Hubs (borrow vaults) | EVK | 1 + 3 | `governorAdmin`: Euler's emergency governor (D12). Hook: P1 |
| Escrow vaults | EVK factory, escrow config | 1 per asset | `governorAdmin`: Euler's emergency governor (D12). Hook: P2 |
| Fallback wrappers | Unmodified OZ `ERC4626` | Only where no issuer wrapper exists | Immutable |
| Euler Earn vaults | Euler Earn `b2fd6e6` | 2 | Owner and curator: `MS_OPS` |
| Emergency governor | Euler `GovernorAccessControlEmergency` (D12) | 1, as `governorAdmin` of every vault | Roles: `MS_OPS` (or its timelock), emergency key |
| Cap steward | Euler `CapRiskSteward` | 1 | Cap steward key, within its factor |
| Timelocks (optional) | OZ `TimelockController`, via Euler's factory | 0 or 2 | Proposer: `MS_OPS` |
| P1 hub guard | **New, Poppie** | 1 | `MS_OPS`; guardian and denylist keys |
| P2 escrow guard | **New, Poppie** | 1 | `MS_OPS`; guardian, scheduler and denylist keys |
| P3 oracle admin guard | **New, Poppie** | 1 | Oracle Safe; guardian; second Safe |
| P4 keeper forwarder | **New, Poppie** | 1 | Oracle Safe via P3; guardian |
| P5 router governor | **New, Poppie** | 1 | `MS_OPS` (adds); timelock (everything else) |
| Oracle Safe, `MS_OPS`, reserve Safe | Safe | 3 | Their signers |

Euler core contracts (EVC, factories, lenses, `ProtocolConfig`) are used at Euler's Arbitrum addresses. The oracle and adapter are compiled with their original settings (solc 0.8.24, `shanghai`) and verified byte-for-byte.

## Governance

Governance has four layers:

1. **Poppie core contracts:** three address slots, now held by Poppie peripheral contracts.
2. **Poppie peripheral contracts:** hub and escrow guards (vault hooks), the oracle admin guard, the keeper forwarder and the router governor.
3. **Stock Euler governance:** Euler's `GovernorAccessControlEmergency` as every vault's governor, with tighten-only emergency roles and a bounded cap steward (D12).
4. **Back-end keys:** the keepers, plus keys that can only tighten or act within bounds.

### 1. Poppie core contracts: three address slots [v1]

| Slot | Contract | Holder | Who acts through it |
| --- | --- | --- | --- |
| `admin` | Oracle | **P3 oracle admin guard** | The Oracle Safe proposes; the guardian can cancel; a second Safe can approve large moves (D13) |
| `keeper` | Oracle | **P4 keeper forwarder** | Several KMS keeper keys; guardian revokes |
| `admin` | Adapter | **`MS_OPS`** | Registers bases at listing |

**One oracle instance.** One oracle and one adapter handle 500 assets (EVAL_FINDINGS A7). The blast radius of the admin and keeper slots is now bounded by P3 and P4.

**Exit path.** P3 and P4 each have a delayed call that hands the slot back to a Safe (`transferAdmin` through P3's longest delay; `setKeeper` to a plain key through P3). A bug in either is fixed by moving the slot, not by upgrading the contract.

### 2. Poppie peripheral contracts **[Poppie]**

Specifications: `docs/peripheralContracts/Peripheral-Contracts.md`. All are immutable, hold no funds, and are configured by roles.

| Contract | Plugs into | Configured by | Hot roles (tighten only) |
| --- | --- | --- | --- |
| P1 hub guard | Each hub's hook slot (`OP_BORROW`, `OP_FLASHLOAN`, `OP_DEPOSIT`, `OP_VAULT_STATUS_CHECK`) | `MS_OPS`: borrow limit and window, fee rate, flash-loan policy, account debt cap | Guardian (pause borrows and flash loans); denylist key (add addresses) |
| P2 escrow guard | Each escrow's hook slot (`OP_DEPOSIT`, `OP_MINT`, `OP_WITHDRAW`, `OP_REDEEM`, `OP_TRANSFER` as needed) | `MS_OPS` | Guardian (pause deposits); scheduler (add issuer windows of bounded length); denylist key |
| P3 oracle admin guard | Oracle `admin` | Oracle Safe; delays and the ±X% band set at deployment | Guardian (`pauseAssets`, cancel queued calls) |
| P4 keeper forwarder | Oracle `keeper` | Oracle Safe (through P3) adds keys | Guardian (revoke a key) |
| P5 router governor | `EulerRouter` governor | `MS_OPS` adds routes; a timelock makes any other change | — |

Removing a denylist entry, lifting a pause early, raising a limit or a fee, and adding a keeper are loosening and need `MS_OPS` or the Oracle Safe.

### 3. Stock Euler governance

As in the zero-contract design (D12): every hub's and escrow's `governorAdmin` is Euler's `GovernorAccessControlEmergency`. `MS_OPS` (or Euler's timelock) holds the governance roles; an emergency key holds the tighten-only roles; `CapRiskSteward` holds bounded cap changes. Because P1 bounds bursts, caps no longer need daily raises; the steward is used for routine cap growth.

Whoever holds the vault governance roles can still change every setting, including **uninstalling P1 or P2** with `setHookConfig`. Alert on every hook change.

| Component | How its access is set | Holder |
| --- | --- | --- |
| EVK vault (hub, escrow) | `setGovernorAdmin` | Euler's emergency governor |
| Vault hook | `setHookConfig` | P1 on hubs, P2 on escrows; installed at vault creation |
| EulerRouter | `transferGovernance` | P5 |
| Euler Earn | `transferOwnership`, `setCurator`, `setIsAllocator` | `MS_OPS` |

### 4. Back-end keys

| Key | On-chain power | Bounded by |
| --- | --- | --- |
| Keeper keys (several) | Push prices; pause up to N assets per day | P4 **[Poppie]**; breaker, cumulative cap, staleness **[v1]** |
| Guardian key | Pause hub borrows and escrow deposits (renewable); cancel queued oracle admin calls; `pauseAssets`; revoke keeper keys | Tighten only **[Poppie]** |
| Scheduler key | Add issuer pause windows to escrows | Bounded window length and count per day **[Poppie]** |
| Denylist key | Add addresses to the denylist | Add only; removal by `MS_OPS` **[Poppie]** |
| Emergency key | Lower caps, lower borrow LTVs, disable a vault | **[Euler]** |
| Cap steward key | Cap changes within a factor | **[Euler]** |
| Deployer key | None after deployment | — |

### Pauses

| Need | Mechanism | Who | Instant | Side effects |
| --- | --- | --- | --- | --- |
| Stop new deposits of a name | P2 guardian pause; or escrow supply cap to current supply | Guardian, emergency key or `MS_OPS` | Yes | Withdrawals and liquidations unaffected |
| Stop new borrowing against a name | Borrow LTV lowered | Emergency key or `MS_OPS` | Yes | At 0, indebted accounts using it freeze |
| Stop new borrowing in a hub | P1 guardian pause (renewable); or borrow cap to current borrows | Guardian, emergency key or `MS_OPS` | Yes | Repay and liquidation continue |
| Limit borrowing speed | P1 hourly borrow limit | Always on | — | Large borrows split across hours |
| Stop pricing a name | Oracle `pauseAssets` through P3 or P4 | Guardian, Oracle Safe, keepers (within budget) | Yes | Wipes the price; recovery needs `adminSetPrice` + push |
| Fix a wrong route | P5 overwrite (timelocked) or `MS_OPS` removing the base on the adapter | `MS_OPS` | Adapter: yes. Router: after the delay | The name is unpriced until re-routed |
| Block a name during issuer pause windows | P2 scheduled windows; app and SDK as well | Scheduler key | Scheduled | Enforced on-chain; liquidations continue |
| Freeze one account | P2 account freeze (optional) | Denylist key | Yes | Its liquidation continues |
| Stop everything on a vault | Hook config: disable all operations | Emergency key or `MS_OPS` | Yes | Blocks repay and liquidation. Catastrophe only; also removes P1 or P2 |

### If an address is compromised

- **Keeper key:** moves prices within the breaker per push; pauses at most N assets per day; the guardian revokes it at once. Other keepers keep pushing.
- **Oracle Safe:** moves prices within ±X% per call instantly; anything larger is queued, alerted and cancellable by the guardian, or needs the second Safe.
- **`MS_OPS`:** can change any vault setting (instantly unless timelocked), uninstall P1 and P2, change P1's limits and fees, and add routes. It cannot overwrite a route without P5's delay.
- **Guardian key:** can keep borrows and deposits paused, cancel oracle admin calls, pause assets and revoke keepers. A denial of service, not a theft; `MS_OPS` and the Oracle Safe replace it.
- **Scheduler key:** can add bounded pause windows (denial of service on deposits and withdrawals).
- **Denylist key:** can block addresses from new positions; `MS_OPS` removes entries.
- **Emergency key, cap steward key:** as in the zero-contract design.

### Risk limits and what enforces them

| Limit | Enforced by |
| --- | --- |
| LTV ceilings per class and band | **[Policy]** |
| LTV raises: ≤ 3 pts per change, once per asset per week | **[Policy]** |
| Liquidation-LTV cuts: ≤ 5 pts per call, ramp ≥ 72h | **[Policy]** |
| Cap ceilings from exit depth | **[Policy]** |
| New borrowing per hub per hour (R2) | **[Poppie]** P1 |
| Origination fee paid on every borrow | **[Poppie]** P1 |
| Sanctioned and denylisted addresses can't borrow, receive borrowed USDC, or deposit | **[Poppie]** P1, P2 |
| Issuer pause windows | **[Poppie]** P2 |
| Instant oracle price writes within ±X% | **[Poppie]** P3 |
| Keeper pauses ≤ N assets per day | **[Poppie]** P4 |
| Routes can be added only to the Poppie adapter; overwrites delayed | **[Poppie]** P5 |
| Emergency changes can only tighten; cap steward changes bounded | **[Euler]** |
| Borrow LTV ≤ liquidation LTV | **[Euler]** |
| Other vault and Earn changes need `MS_OPS`'s threshold (and the timelock, if chosen) | **[Safe]** / **[Euler]** |
| Escrows cannot be borrowed from | **[Euler]** |

## Risk automation

The engine watches exit liquidity, volatility, earnings and corporate actions, market sessions, hub concentration, the USDC peg and the risk metrics (R1–R10). It proposes changes to `MS_OPS`. It may itself drive the cap steward key (bounded cap changes) and, on a page-level alert, the guardian and emergency keys (tighten only).

| When | What it proposes |
| --- | --- |
| On a breach | Tightening |
| Daily | Target updates; routine cap growth through the cap steward; borrow-limit and other raises to `MS_OPS` |
| Before earnings or a corporate action | Supply-cap freeze; borrow-LTV cut if needed |

## Listing

1. The engine assigns the name a class, band and hub, after the issuer checks.
2. A deployer key creates the escrow vault from Euler's factory, installs P2 as its hook, makes the seed deposit and hands governance to Euler's emergency governor.
3. The Oracle Safe calls `configureAssets` and `adminSetPrice`. From then on the keeper pushes the asset, so its price is fresh when the route goes live. `registerBase` needs the asset configured, not a live price.
4. An `MS_OPS` batch:
   - registers the base on the adapter;
   - adds the route through P5 (instant; only to the Poppie adapter) and the escrow's resolved-vault entry;
   - sets launch LTVs at half the class ceiling;
   - sets finite launch caps.
5. `MS_OPS` steps it up over time **[Policy]**.

Before each batch, a config-check script verifies:

- routes point to the Poppie adapter;
- wrappers are never resolved vaults;
- escrows come from Euler's factory;
- caps are finite;
- every hub has P1 and every escrow has P2 installed, with the expected hooked operations (never repay or liquidation);
- the name's issuer pause schedule is loaded and served to the app and SDK.

Listings are instant through P5; route overwrites wait for P5's timelock. Vault settings have no notice period unless D12 is timelocked. The config-check script and decoded, simulated review of every batch are the protection **[Policy]**.

## Monitoring

In addition to the shared alerts in `docs/Overview.md` ("Monitoring"):

- **Oracle admin:** any threshold, staleness, window or keeper change; every call through P3.
- **Sanctions:** deposits, borrows or receivers on the Chainalysis list (R9); every P1 or P2 sanctions revert.
- **Peripheral contracts:** any hook change on a hub or escrow (page if P1 or P2 is removed); P1 borrow limit reached; guardian pauses and renewals; scheduler windows; denylist additions; P3 queued, executed and cancelled calls; P4 key changes and pause-budget use; P5 queued overwrites.

## Audits

| Track | Scope |
| --- | --- |
| Poppie peripheral contracts | P1–P5, and their integration with EVK hooks, the EVC batch and the v1 oracle; invariants: repay and liquidation never blocked, no custody, no upgrades |
| Deployment and configuration | The grant scripts and check script; Safe thresholds; roles on Euler's emergency governor, cap steward and P1–P5; byte-for-byte verification of the oracle and adapter |
| Off-chain systems | Keeper, corporate-action engine, alerting, pause-window sync to app and SDK |
| Economic | Class and band thresholds; breaker and cap sizing against real weekend, earnings and split gaps |

## Rollout

| Phase | Scope | Gate to next phase |
| --- | --- | --- |
| 0 | Keeper extended from BSC (multiplier and stock-price gates, per-issuer rules, chunking): **prototyped** on an Arbitrum fork against the real xStocks contracts (KEEP-2 to KEEP-20); still to do: live vendor data, a corporate-action feed, an issuer interface, production wiring and state storage, the v2 monitor. Fork test that a third party can liquidate through Enso (liquidate, unwrap, sell, repay). EVK harness and Arbitrum fork tests: stale-price and cap behaviour, Earn accepting the hubs, 300+ LTV entries in one hub, `ProtocolConfig` values. (A real xStocks multiplier change through the router and adapter already passes: `eval/fork/`). P1–P5 written, tested on the EVK harness and an Arbitrum fork, and audited | All pass; audit findings closed; issuer questions answered; exit route confirmed per name |
| 1 (~100 assets) | Prime hub plus 3 band hubs; both Earn vaults | Check script passes; alerts live |
| 2 (→ 500 assets) | More names; more hubs per band if needed | — |

Alternative: launch phase 1 as the zero-contract design and add P1–P5 as each passes audit. Each is independent; P3 and P1 first, since they bound the largest risks.

## Decisions

Shared decisions (D1–D4, D7, D9–D11, D18) are in `docs/Overview.md`. Design-specific:

| ID | Decision | Status |
| --- | --- | --- |
| D5 | Listing | Instant, by `MS_OPS` through P5 (add-only); overwrites timelocked |
| D6 | `adminSetPrice` | Oracle Safe through P3: within ±X% instant; larger moves delayed or second-approved; on-call signer rota |
| D8 | Issuer pause windows | On-chain through P2, plus app and SDK; alerts matched to schedules |
| D12 | Vault governance | Proposed: Euler's `GovernorAccessControlEmergency` as every vault's `governorAdmin`, with an emergency key and `CapRiskSteward`. Open: `MS_OPS` instant, or behind Euler's timelocks (≥ 1 day) |
| D13 | Oracle admin | Proposed: P3. Open: the instant band ±X%, the delay, and whether a second Safe can approve large moves at once |
| D14 | Keeper slot | Proposed: P4 with several keys. Open: the daily pause budget N |
| D15 | Hub and escrow hooks | Proposed: P1 on every hub, P2 on every escrow. Open: the hourly borrow limit per hub and its window; whether to enable the account debt cap |
| D16 | Origination fee | Proposed: enforced by P1, per hub; rates and the on-chain maximum to set (or 0 at launch) |
| D17 | Sanctions | Proposed: P1 and P2 screen borrowers, receivers and depositors. Open (counsel): whether P2's account freeze exists |
| D19 | Contract set | Open: which of P1–P5 to build before launch (audit budget) |

## Known blockers and limitations

Items 1–9 are shared (`docs/Overview.md`). Design-specific:

10. **`MS_OPS` holds vault power.** It can change any vault setting (instantly unless D12 is timelocked) and uninstall P1 and P2. Route overwrites wait for P5's delay. Users must trust its signers.
11. **Keeper and oracle admin are bounded, not removed.** A stolen keeper key moves prices within the breaker and pauses up to N assets per day; a compromised Oracle Safe moves prices within ±X% per call.
12. **New audit scope and hook liveness.** P1–P5 are new code. A bug in P1 or P2 can block borrowing or deposits until uninstalled; a bug in P3 or P4 can block admin calls or pushes until the slot is moved. Repay and liquidation are never hooked.
13. **No seizure and no pre-listing detection.** Stolen funds can't be frozen before an address is listed, and no contract can seize or return funds.

## Expectations for integrators

In addition to the shared expectations in `docs/Overview.md`:

- **Risk limits:** set by Poppie's published policy, stock Euler settings and P1–P5. New borrowing per hub is limited per hour; a large borrow may need to wait for the next window.
- **Borrowing:** every borrow must be an EVC batch that also borrows the fee to the hub's fee receiver; a direct `borrow` reverts while a fee is set. Borrowing the full available cash is rejected.
- **Sanctions:** borrows, borrow receivers and deposits by listed or denylisted addresses revert on-chain (P1, P2). Repay and liquidation of such accounts still work.
- **Pause windows:** deposits and withdrawals of a name revert during its issuer's published pause windows (P2), for direct calls too. Borrowing, repaying and liquidation continue.
- **Guardian pauses:** borrows on a hub or deposits into an escrow can be paused by a guardian for a set time, renewable.
- **Changes:** tightening takes effect immediately. Listings are immediate; route overwrites wait for P5's delay; risk raises are immediate unless D12 is timelocked; large oracle admin price writes wait for P3's delay.

## Deferred

Shared deferred items (dividend capture, a Poppie-run liquidator) are in `docs/Overview.md`.

- **More contracts:** a Poppie-run liquidator (above), dividend capture (above). Any peripheral contract not built at launch (D19).
