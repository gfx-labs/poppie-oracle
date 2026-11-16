# Poppie on Arbitrum: Hub Architecture & Governance Plan

*This is the **zero-contract design**: Poppie deploys no new contracts. Risk management is its primary goal; see "Risk management" for the risks, the levers that bound them, and what this design cannot do. The alternative, which adds small Poppie contracts around the same core, is `docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`; the gap-by-gap comparison is `docs/Design-Comparison.md`. Risk metrics: `docs/Risk-Metrics.md`. Sections shared by both designs are in `docs/Overview.md`.*

## TL;DR

Poppie lends USDC on Euler V2 against tokenized equities, from about 100 assets at launch toward 500.

- **Contracts:** Poppie's existing `PoppieEulerOracle` and `PoppieEulerAdapter` (tag `v1-bsc`) are redeployed unchanged. Everything else is stock:
  - Euler: EVK, EulerRouter, Earn, and Euler's governance contracts (`GovernorAccessControlEmergency`, `CapRiskSteward`, optionally `HookTargetGuardian` and timelocks);
  - Safe, Zodiac Roles and OpenZeppelin `TimelockController`.

  **No new Poppie contracts.**
- **Hubs:** one Prime hub (blue chips only) plus one hub per long-tail risk band. Each band hub holds all blue chips and that band's long-tail names.
- **Lenders:** deposit USDC into Prime Earn or Yield Earn, which allocate across the hubs.
- **Revenue:** interest fee and rate floor per hub, plus Earn performance fees. Part of Poppie's share funds a loss reserve.
- **Prices:** a keeper, extended from the BSC keeper, pushes one USD price per asset, used for both borrowing and liquidation. The oracle bounds each push and the drift per window. Before pushing, the keeper checks the stock price against an independent source and the multiplier against the issuer, and skips the name on a mismatch (D11).
- **Closed markets:** one rule. Push whenever a reliable price exists; otherwise let the price go stale, which freezes affected accounts until reopen.
- **Control:** the Oracle Safe holds the oracle admin; `MS_OPS` governs the hubs, escrows, router, adapter and Earn through Euler's emergency governor (D12). Back-end keys can only push prices within bounds (keeper), tighten (emergency key) or raise caps within a bounded factor (cap steward). A timelock on loosening changes is optional.
- **Risk:** losses are bounded by limits set in advance: supply caps per name and issuer, borrow-cap headroom per hub, LTV buffers and the loss reserve. Tightening is instant; loosening needs `MS_OPS`. This design cannot freeze individual accounts, rate-limit borrowing except through cap headroom, bound the Oracle Safe without delaying all its actions, or enforce sanctions screening, the origination fee or issuer pause windows on direct contract calls (see "Risk management").
- **Issuers:** only tokens whose dividends are reinvested. Rebasing tokens enter through the issuer's non-rebasing wrapper, and the **wrapper share** is the priced asset. Tokens with static balances and a multiplier (ERC-8056, e.g. Robinhood) are held and priced directly.
- **Main open risk:** no issuer has a listable market on Arbitrum today. xStocks' contracts fit this design (tested on an Arbitrum fork), but nearly all supply is Backed inventory and there are no DEX pools. The only exit is Backed's inventory via its allowlisted `AtomicSwap`. Backed quotes up to $1M per trade on majors in market hours and $10k on long-tail names overnight, with nothing executable at weekends. Backed will not liquidate itself. Poppie will not onboard with any issuer and runs no liquidator at launch. Third parties can sell through Enso, which Backed already allowlists, and the plan caps exposure to the exit that exists (D9). Dinari's wrapper lets the issuer remove backing. Ondo is not deployed. Robinhood Stock Tokens fit with no wrapper (tested on a Robinhood Chain fork) but are not yet on Arbitrum, and Robinhood keys can burn from any holder. Reality's rTokens are on Arbitrum and fit with no wrapper (tested on a fork), but 97–100% of supply sits in two or three EOAs, their contracts are unverified, and their corporate-action record has errors (D10).
- **Price coverage:** Chainlink Data Streams covers 71 of the 1,488 xStocks names on Arbitrum, below the ~100 planned for launch. More names need more Chainlink feeds or a second primary source (KEEP-4).

| Choice | Gain | Cost |
| --- | --- | --- |
| Reuse the existing oracle | No new oracle code to audit | One price for borrowing and liquidation; pause wipes price state; one admin and one keeper address |
| Stock Euler contracts, governed by a Safe through Euler's emergency governor | Nothing new to audit; no Poppie code in the borrow path; instant tightening by a hot key; bounded cap raises without signing | Coarse on-chain limits; no per-account controls; no borrow rate limit; Oracle Safe unbounded or fully delayed; users trust `MS_OPS`'s signers |
| One hub per band | Deep liquidity, simple config | Lenders in a hub share every name's risk |
| Reinvesting issuers only | No dividend handling | Smaller listable set |

Euler allows at most 10 collaterals per account, so large portfolios need several sub-accounts. All numbers are proposed starting values.

## How to read the controls in this plan

| Label | Meaning |
| --- | --- |
| **[v1]** | Enforced by `PoppieEulerOracle` or `PoppieEulerAdapter` |
| **[Euler]** | Enforced by stock Euler code (EVK, EulerRouter, evk-periphery, Earn) |
| **[Safe]** | Enforced only by a Safe's signer threshold |
| **[Policy]** | Enforced only by Poppie's back end or runbooks. Not visible to or enforceable by the chain |

Anything labelled **[Policy]** is a promise, not a guarantee, and must be published as such.

Three Safes are used:

- **Oracle Safe**: holds the oracle admin.
- **`MS_OPS`**: 3-of-5; governs the hubs, escrows, router, adapter and Earn.
- **Reserve Safe**: holds the loss reserve.

## Risk management

Risk management is the primary goal of this design. This chapter lists what can go wrong, which levers bound each risk, how fast each lever acts and who holds it, and what this design cannot do. The metrics (R1–R10) are defined in `docs/Risk-Metrics.md`. The same risks, with the levers the peripheral design adds, are in `docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`; the gap-by-gap comparison is `docs/Design-Comparison.md`.

### Principles

1. **Losses are bounded by what is set in advance, not by how fast we react.** The Kelp/Aave attacker borrowed about $230M within minutes; a Safe takes minutes to hours to sign. So supply caps, borrow-cap headroom and LTVs, set before an incident, are the real bound. Response levers only stop it from growing.
2. **Tightening is fast; loosening is slow.** Keys that can only tighten may be hot and act in seconds. Anything that raises exposure needs `MS_OPS`, or a bounded steward.
3. **Repay and liquidation stay open.** Every lever below except the vault-wide disable leaves them working, so a freeze never traps a borrower or blocks the hub from recovering.
4. **Anything labelled [Policy] is a promise, not a guarantee.**

### Risk appetite

Set by Poppie, not yet set: the largest loss from one issuer's collateral turning out unbacked (`L_issuer`), the largest loss from one fast event (`L_event`), the largest account's share of a hub's debt (`C_account`), and the time to freeze (`T_freeze`). Caps, borrow-cap headroom and the loss reserve are sized from them (`docs/Risk-Metrics.md`, R1–R3, R7–R8).

### Risk register

| Risk | Levers in this design | What bounds the loss | What remains |
| --- | --- | --- | --- |
| **Unbacked or forged collateral**: an issuer minter key is stolen, an issuer upgrade goes wrong, or a bridged token is exploited (the Kelp route) | No bridged tokens at launch **[Policy]**; supply caps per name and per issuer (R1) **[Euler]**; hub borrow cap kept a set headroom above borrows (R2) **[Euler]**; alerts on issuer mints, upgrades and supply jumps; emergency freeze of caps or borrow LTV | The smaller of R1 and R2 | Up to that bound is lost before anyone acts; the reserve covers it (R3) |
| **Wrong price within the oracle's bounds** (keeper bug, bad feed, wrong multiplier) | Keeper's blocking gates (D11) **[Policy]**; per-push breaker and cumulative cap **[v1]**; borrow headroom (R2); emergency freeze | Breaker and cumulative cap per name; R2 across hubs | A wrong price inside the breaker goes live until the next push or a freeze |
| **Issuer multiplier error** (HONx, SOXX) | Keeper's multiplier gate: unexplained changes are not pushed (KEEP-11) **[Policy]** | The price stays at the last good value | Wrapper balances already reflect the error; the name goes stale until fixed |
| **Oracle Safe compromised** | Signer hygiene; alerts on every admin call; option to put the oracle admin behind a timelock (D13) | **None** if the admin is a Safe: any price, instantly. With a timelock: nothing lands before the delay | Unbounded (Safe) or slow corrections (timelock). R2 limits how much can be borrowed against a forged price |
| **Keeper key stolen** | Breaker and cumulative cap **[v1]**; Oracle Safe revokes with `setKeeper`; keeper behind a Safe with Zodiac Roles (D14) | Breaker per push, cumulative cap per window | It can pause **every** asset, wiping every price; recovery is about 12M gas of `adminSetPrice` |
| **`MS_OPS` compromised** | Signer hygiene; decoded, simulated review; alerts on every governance change; Euler's emergency governor, with optional timelocks (D12) | Without a timelock, nothing: any LTV, route or hook, instantly. With a timelock: visible for the delay and cancellable | Users trust its signers |
| **Liquidations fail** (thin exit, weekends) | Caps sized to exit depth per priced session, LTV buffers, discounts, session gating, loss reserve (see `docs/Overview.md`, "Thin liquidity and liquidations") **[Policy]** | Exit depth × cap share per name (R5) | Bad debt above the reserve is socialized (`MS_OPS` turns loss-sharing on) |
| **Gap through the breaker** (Monday open, earnings) | Price goes stale (borrow, withdraw and liquidation freeze for holders); LTV buffers; pre-built `adminSetPrice` batches | LTV buffer per class | Stale names can't be liquidated until the Oracle Safe signs |
| **Issuer burns from, freezes or pauses an escrow** | Per-issuer caps; alerts; `pauseAssets`; LTV cuts | R1 for that issuer | Escrow cash is overstated after a burn; the last depositors can't withdraw |
| **Stolen funds or sanctioned users** | Issuer-token and USDC screening; app and SDK screening (see "Sanctions") | Nothing on-chain beyond the issuer and USDC lists | Direct contract callers are not screened by Poppie; funds can't be frozen or returned |
| **Lender run** | Kink IRM; Earn allocation; utilization alerts (R6) | Utilization above the kink makes borrowing expensive | Lenders wait for repayments or liquidations |
| **USDC depeg or a Circle blacklist of a hub** | Alerts; borrow-cap freeze | — | Route is a fixed rate; a blacklisted hub's USDC is frozen |
| **Arbitrum sequencer outage** | Keeper waits after a restart (KEEP-17) | — | Liquidations resume on the first push |
| **Bug in Euler, Safe or the v1 contracts** | Audits by their authors; caps | R1, R2 | Outside Poppie's control |

### Levers to restrict capital

| Lever | Who holds it | Speed | Stops | Leaves working | Enforced by |
| --- | --- | --- | --- | --- | --- |
| Escrow supply cap down to current supply | Emergency key, or `MS_OPS` | Seconds (key), minutes to hours (Safe) | New collateral in one name | Withdraw, liquidation | **[Euler]** |
| Hub borrow cap down to current borrows | Emergency key, or `MS_OPS` | Same | All new borrowing in one hub | Repay, liquidation | **[Euler]** |
| Borrow LTV lowered for a name | Emergency key, or `MS_OPS` | Same | Borrowing power against that name; at 0, every indebted account using it freezes | Repay, liquidation | **[Euler]** |
| Borrow-cap headroom (cap = borrows + headroom, raised daily) | Cap steward key, within a bounded factor | Daily | Bursts larger than the headroom | Everything | **[Euler]** `CapRiskSteward` |
| Pause borrows and flash loans on a hub, for a fixed time | Guardian on Euler's `HookTargetGuardian` (D15) | Seconds | Borrowing and flash loans | Repay, liquidation, deposits | **[Euler]** |
| Disable all operations on a vault | Emergency key (hook role), or `MS_OPS` | Seconds (key) | Everything, including repay and liquidation | Nothing | **[Euler]**; catastrophe only |
| `pauseAssets` | Keeper or Oracle Safe | Seconds (keeper) | Pricing of a name; wipes its price | — | **[v1]** |
| Liquidation-LTV cut with a ramp | `MS_OPS` | Hours | Winds a name down | — | **[Euler]** |
| Earn allocation to a hub to 0 | `MS_OPS` (curator) | Minutes to hours | New lender USDC into a hub | Existing deposits | **[Euler]** |
| Stop listing an issuer; delist | `MS_OPS` | Hours to days | New exposure | — | **[Policy]** |

The emergency key holds Euler's emergency roles on `GovernorAccessControlEmergency`: it can only lower caps, lower borrow LTVs (liquidation LTV untouched), or disable a vault. It cannot raise anything (D12).

### What this design cannot do

Poppie writes no contracts, so it has no on-chain way to:

- **freeze, seize or return one account's funds**, for a court order, a regulator or a hack victim;
- **limit borrowing per hour.** The only rate limit is borrow-cap headroom, which costs daily cap raises and "cap reached" errors on busy days;
- **bound the Oracle Safe.** It either sets any price instantly, or every admin action waits for a timelock, including legitimate gap corrections;
- **limit how many assets a keeper key can pause.** One stolen key can wipe every price;
- **list instantly while delaying route overwrites.** Router changes are either all instant or all timelocked;
- **screen direct contract callers for sanctions**, beyond the issuer tokens' and USDC's own lists;
- **enforce the origination fee.** The SDK charges it; direct callers don't pay;
- **enforce issuer pause windows on-chain.** The app and SDK block them; direct callers rely on the issuer's own pause;
- **cap one account's debt.**

### What not writing contracts saves

- **No new audit scope.** The only Poppie code on-chain is the audited oracle and adapter. Euler's governor, steward and guardian are Euler-written (audit coverage at our pin to confirm).
- **No new liveness risk.** No Poppie hook sits in the borrow or deposit path, so a Poppie bug can't block borrowing, deposits or withdrawals.
- **Simpler integration.** Integrators call EVK directly; no batch is required for a borrow.
- **Less gas** per borrow and deposit, and per push.
- **Fewer keys and parameters** to secure and tune.
- **Faster to launch**, and nothing to upgrade or migrate later.

### Compared with the peripheral design

The peripheral design adds five small Poppie contracts in slots the core already exposes. It closes the first eight items in "What this design cannot do", except seizing funds, which neither design can do. It costs new audit scope, a hook in the borrow path, and a few more keys. Gap by gap: `docs/Design-Comparison.md`.

### Sanctions

**On-chain today, with no Poppie code:**

- xStocks tokens and V2 wrappers check Chainalysis's on-chain list (`0x40C5…C8fb` on Arbitrum) for every sender, receiver and spender, and on wrap and unwrap. A listed address can't deposit or withdraw xStocks.
- Robinhood's registry blocks listed addresses (`BLOCKER_ROLE`).
- Circle's USDC blacklist blocks a listed address from receiving borrowed USDC or repaying. If Circle blacklisted a hub, its USDC would freeze.

**Poppie can:** screen addresses, including borrow receivers, in the app and SDK before building any transaction; geo-block the app; publish terms; monitor listed addresses' on-chain activity (R9); tighten caps or LTVs for everyone in response.

**Poppie can't:** stop a listed address that calls the contracts directly, except where the issuer token or USDC blocks it; freeze or return one account's funds; catch an attacker before they are listed (lists lag, often by days); stop a listed account being liquidated.

Poppie needs a legal view on whether this is enough before launch, and counsel ready for claims like the one Aave faced over the Kelp funds.

## Shared design

The following are identical in both designs and live in `docs/Overview.md`: How it works, Asset classes, Issuers (xStocks, Dinari, Robinhood, Reality), Hubs (bands, revenue, loss reserve), Thin liquidity and liquidations, Prices and closed markets (oracle bounds, keeper, price sources, closed markets, corporate actions), shared monitoring, shared decisions (D1–D4, D7, D9–D11, D18), known blockers 1–9, open gaps and shared deferred items. Below are only the parts that differ in this design.

## Flash loans and fees

Flash loans of hub USDC are left at the EVK default (on, free), so third-party liquidators need no capital where the exit is atomic (a DEX pool, or a sale through Enso to Backed). `MS_OPS` can disable them later with a hook-config change.

- **Origination fee (SDK only, D16):** Poppie's app and SDK add a second borrow in the same EVC batch, `hub.borrow(fee, feeReceiver)`, next to the user's `hub.borrow(amount, receiver)`. The fee becomes part of the user's debt, so a first-time borrower needs no USDC up front, and no Poppie contract holds funds. Nothing enforces it: direct callers, other front ends and aggregators pay no fee. Plan revenue on the interest fee and rate floor; treat the origination fee as extra.

## Issuer pause windows [Policy]

Issuers pause assets on-chain for scheduled operations. Example: Ondo pauses with reason `ASSET_PAUSED` for 20 minutes (00:52–01:12 UTC, weekdays) to apply its daily dividend share-multiplier update.

- **Schedule:** the back end loads each issuer's pause schedule (status API, or on-chain schedules such as xStocks' `multiplierUpdates`) and serves it to the app and SDK.
- **App:** during a window, plus a few minutes' buffer, deposit and withdraw for that name are disabled, with a banner.
- **SDK:** deposit and withdraw calls for that name throw a typed error during a window. Borrow, repay and liquidation are unaffected.
- **On-chain:** the issuer's own pause enforces the freeze, since token transfers revert. Poppie does not block direct contract calls.
- **Pricing:** the keeper skips pushes for that name during the window, and applies the issuer's new multiplier from its activation time. Daily dividend changes are far below the breaker.
- **No on-chain pause:** unlike the BSC keeper, which calls `pauseAssets` when Ondo reports `ASSET_PAUSED`, the v2 keeper doesn't pause the oracle for scheduled windows: a pause wipes the price and needs the Oracle Safe to re-seed it (PAUSE-1).
- **Notify:** an issuer pause inside a known window is logged, not paged. An unscheduled pause, or one that outlasts its window, pages on-call (see Monitoring, here and in `docs/Overview.md`).

## Contracts Poppie deploys on Arbitrum

No Poppie-written contract is deployed. Euler's governance contracts are used as published at the `evk-periphery` pin; their audit coverage at that pin is to confirm.

| Contract | Code | Count | Controlled by |
| --- | --- | --- | --- |
| `PoppieEulerOracle` | Existing, audited | 1 | `admin`: Oracle Safe. `keeper`: keeper key |
| `PoppieEulerAdapter` | Existing, audited | 1 | `admin`: `MS_OPS` |
| USDC/USD fixed-rate oracle | Euler `FixedRateOracle` | 1 | Immutable |
| EulerRouter | Euler | 1 | Governor: `MS_OPS` |
| Kink IRMs | Euler IRM factory | 1 per band, plus Prime | Set by `MS_OPS` |
| Hubs (borrow vaults) | EVK | 1 + 3 | `governorAdmin`: Euler's emergency governor (D12); roles held by `MS_OPS` |
| Escrow vaults | EVK factory, escrow config | 1 per asset | `governorAdmin`: Euler's emergency governor (D12) |
| Fallback wrappers | Unmodified OZ `ERC4626` | Only where no issuer wrapper exists | Immutable |
| Euler Earn vaults | Euler Earn `b2fd6e6` | 2 | Owner and curator: `MS_OPS` |
| Emergency governor | Euler `GovernorAccessControlEmergency` (D12) | 1, as `governorAdmin` of every vault | Roles: `MS_OPS` (or its timelock), emergency key |
| Cap steward | Euler `CapRiskSteward` | 1 | Cap steward key, within its factor |
| Timelocks (optional) | OZ `TimelockController`, via Euler's factory | 0 or 2 | Proposer: `MS_OPS` |
| Hub guardian (optional, D15) | Euler `HookTargetGuardian` | 1 | Guardian key |
| Keeper Safe (optional, D14) | Safe + Zodiac Roles | 1 | Keeper keys may call only `keeperPushPrices`, `pauseAssets` |
| Oracle Safe, `MS_OPS`, reserve Safe | Safe | 3 | Their signers |

Euler core contracts (EVC, factories, lenses, `ProtocolConfig`) are used at Euler's Arbitrum addresses. The oracle and adapter are compiled with their original settings (solc 0.8.24, `shanghai`) and verified byte-for-byte.

## Governance

Governance has three layers:

1. **Poppie contracts:** three address slots.
2. **Stock Euler contracts:** each vault's governor is Euler's `GovernorAccessControlEmergency` (proposed, D12), which splits `MS_OPS`'s powers from tighten-only emergency roles and a bounded cap steward.
3. **Back-end keys:** the keeper, plus keys that can only tighten or raise caps within bounds.

### 1. Poppie contracts: three address slots [v1]

The oracle and adapter have no role system. Each slot holds one address, which may be a key or a contract, and that address has every power of the slot.

| Slot | Contract | Functions | Changed by | Holder |
| --- | --- | --- | --- | --- |
| `admin` | Oracle | `configureAssets`, `setAssetThresholds`, `adminSetPrice`, `setMaxPriceAge`, `setAssetMaxPriceAge`, `setAnchorWindow`, `setKeeper`, `pauseAssets`, `transferAdmin` | `transferAdmin`, then `acceptAdmin` | **Oracle Safe** (D13: or an OZ timelock whose proposer is the Oracle Safe). Kept separate from `MS_OPS` so a compromise of one does not give the other's powers |
| `keeper` | Oracle | `keeperPushPrices`, `pauseAssets` | `setKeeper` from the oracle admin (instant) | **Keeper key** (KMS); D14: or a keeper Safe with a Zodiac Roles module so several KMS keys can push |
| `admin` | Adapter | `registerBase`, `unregisterBase`, `transferAdmin` | `transferAdmin`, then `acceptAdmin` | **`MS_OPS`**, as part of listing |

**One oracle instance.** One oracle and one adapter handle 500 assets: a 500-asset push measured 3.55M gas (EVAL_FINDINGS A7). The trade-off is blast radius: one admin and one keeper cover every name.

**The Oracle Safe is the largest unbounded trust point.** As a Safe it can, instantly and without bounds, write any price, widen thresholds, disable staleness and replace the keeper. With no new contracts there are only two settings (D13):

| Option | Bound | Cost |
| --- | --- | --- |
| A. Safe | None. Hardware wallets, independent calldata checks, alerts on every admin event | — |
| B. Timelock (proposer: Oracle Safe; canceller: a second Safe) | Nothing lands before the delay; any call can be cancelled | Every `adminSetPrice`, including gaps beyond the breaker and re-seeds after a pause, waits for the delay; those names stay stale longer. Emergency `pauseAssets` stays with the keeper |

### 2. Stock Euler governance

**Proposed (D12):** every hub's and escrow's `governorAdmin` is Euler's `GovernorAccessControlEmergency` (`evk-periphery` `96b83f8`) rather than `MS_OPS` directly. It forwards governance calls by per-function role:

| Role | Holder | Allows |
| --- | --- | --- |
| Every governance function (setLTV, setCaps, setHookConfig, IRM, fees, flags, governor) | `MS_OPS`; or, through Euler's factory, a "wildcard" timelock proposed by `MS_OPS` (delay ≥ 1 day) | Everything, as today |
| `CAPS_EMERGENCY_ROLE` | Emergency key | Lower supply or borrow caps only, instantly |
| `LTV_EMERGENCY_ROLE` | Emergency key | Lower a borrow LTV only, instantly; liquidation LTV and its ramp untouched |
| `HOOK_EMERGENCY_ROLE` | Emergency key | Disable all operations on a vault, instantly (catastrophe only; blocks repay and liquidation) |
| `setCaps` | Euler's `CapRiskSteward`, driven by the cap steward key | Raise or lower caps within a factor that recharges over time (`MAX_ADJUST_FACTOR`, `CHARGE_INTERVAL`); set IRMs only from Euler's IRM factory |
| Admin of the governor itself | `MS_OPS`, or Euler's factory's admin timelock (delay ≥ the wildcard delay) | Grant and revoke roles |

Two settings for `MS_OPS`'s own calls (D12):

| Setting | Effect |
| --- | --- |
| **Instant** (governor deployed directly; `MS_OPS` holds the roles) | Listings, LTV raises and fixes are instant, as in the original plan. Gains the emergency key and the steward only |
| **Timelocked** (Euler's factory; ≥ 1 day) | Every loosening change is public for the delay and cancellable. Listings and LTV raises wait for it; tightening stays instant through the emergency roles |

| Component | How its access is set | Holder |
| --- | --- | --- |
| EVK vault (hub, escrow) | `setGovernorAdmin` | Euler's emergency governor (D12) |
| EulerRouter | `transferGovernance` | `MS_OPS`, or the same timelock (to verify that Euler's governor can front the router) |
| Euler Earn | `transferOwnership`, `setCurator`, `setIsAllocator` | Owner and curator: `MS_OPS`. The curator can also allocate |
| Safe | Owners and threshold | As listed above |

Whoever holds the governance roles holds every setting of every hub and escrow. Verified from source at EVK `422bf24`:

- **LTVs:** any LTV within Euler's rules. It can also cut a liquidation LTV with no ramp, which liquidates accounts at once.
- **Caps:** any cap. A raw cap of 0 means unlimited in EVK, so "closed" means the lowest finite cap.
- **Hook config:** it can disable **all** operations on a vault, including repay and liquidation, and undo that with the same call. It can also install an arbitrary hook contract. Each vault has one hook slot.
- **Also:** interest rate models, interest fee, config flags, fee receiver, liquidation discount, and the vault's governor.
- **Router and adapter:** it can add, overwrite or delete any route, and register or remove any base.

A deployment script makes every assignment, and a check script reads them all back and diffs them against this section, before launch and after every change.

### 3. Back-end keys

| Key | On-chain power | Bounded by |
| --- | --- | --- |
| Keeper key(s) | Oracle `keeper` slot: push prices, pause assets | Breaker, cumulative cap and staleness **[v1]**; Roles module if D14 |
| Emergency key | Lower caps, lower borrow LTVs, disable a vault | Euler's emergency roles: tighten only **[Euler]** |
| Cap steward key | Raise or lower caps within the steward's factor; set factory IRMs | `CapRiskSteward` **[Euler]** |
| Guardian key (if D15) | Pause hooked hub operations (borrow, flash loan) for a fixed time | `HookTargetGuardian`'s duration and cooldown **[Euler]** |
| Deployer key | None after deployment: creates escrows and makes seed deposits, then renounces everything | — |

The risk engine proposes; the cap steward key executes bounded cap raises, and `MS_OPS` signs everything else after decoded, simulated review **[Policy]**. The emergency and guardian keys are held by on-call staff and by the monitoring system, which can freeze automatically on a page-level alert.

### Pauses

| Need | Mechanism | Who | Instant | Side effects |
| --- | --- | --- | --- | --- |
| Stop new deposits of a name | Escrow supply cap set to current supply | Emergency key or `MS_OPS` | Yes (key) | Withdrawals and liquidations unaffected (to confirm on EVK) |
| Stop new borrowing against a name | Borrow LTV lowered (to 0 if needed) in each hub | Emergency key or `MS_OPS` | Yes (key) | At 0, every indebted account relying on that name freezes (no borrow, no withdraw) until it repays or adds collateral |
| Stop new borrowing in a hub | Hub borrow cap to current borrows; or the guardian pause (D15) | Emergency key, guardian or `MS_OPS` | Yes | `AmountCap` rounding to confirm on EVK. The guardian pause expires and has a cooldown |
| Stop pricing a name (e.g. a wrong price or wrong base decimals) | Oracle `pauseAssets` | Oracle admin or keeper (emergencies only) | Yes | Accounts holding it freeze; recovery needs `adminSetPrice` + push |
| Fix a wrong route or base | Router `govSetConfig`, adapter `unregisterBase` | `MS_OPS` | Yes, unless timelocked | The name is unpriced, so accounts holding it freeze until it is re-routed |
| Block a name during issuer pause windows | App and SDK block deposit and withdraw | Back end | Scheduled | Direct contract calls are not blocked; the issuer's own pause enforces on-chain |
| Stop everything on a vault | Hook config: disable all operations | Emergency key or `MS_OPS` | Yes | Blocks repay and liquidation while active; undone by `MS_OPS`. Catastrophe only |

Pauses other than the guardian's have no on-chain time limit; they last until reversed.

### If an address is compromised

- **Keeper key:**
  - can move each price by up to the breaker per push and the cumulative cap per window;
  - can pause **every** asset, wiping all prices and freezing the market;
  - is revoked with `setKeeper` from the oracle admin (or removed from the keeper Safe's Roles module, D14);
  - recovery from a full wipe is about 12M gas of `adminSetPrice` calls. Keep the batch pre-built and rehearsed.
- **Oracle Safe signers:** can set any price instantly (D13 option A), or queue changes that the canceller can stop (option B).
- **`MS_OPS` signers:** can do anything to the hubs, escrows, router, adapter and Earn: change any LTV or cap, liquidate accounts by cutting liquidation LTVs, repoint any price route, install a hook that blocks withdrawals, or change rates and fees. Instantly, or after the timelock delay if D12 is timelocked.
- **Emergency key:** can freeze caps, lower borrow LTVs or disable vaults. That is a denial of service, not a theft; `MS_OPS` revokes the role and restores settings.
- **Cap steward key:** can raise caps by the steward's factor per charge interval. Bounded; `MS_OPS` revokes it.
- **Guardian key:** can keep borrowing paused, one fixed period per cooldown.

### Risk limits and what enforces them

| Limit | Enforced by |
| --- | --- |
| LTV ceilings per class and band | **[Policy]** |
| LTV raises: ≤ 3 pts per change, once per asset per week | **[Policy]** |
| Liquidation-LTV cuts: ≤ 5 pts per call, ramp ≥ 72h | **[Policy]** |
| Cap ceilings from exit depth | **[Policy]** |
| Borrow-cap headroom above current borrows (R2) | **[Policy]**, kept by the cap steward key |
| Cap raises by the back end: bounded factor per interval | **[Euler]** `CapRiskSteward` |
| Emergency changes can only tighten | **[Euler]** `GovernorAccessControlEmergency` |
| Borrow LTV ≤ liquidation LTV | **[Euler]** |
| All other hub, escrow, router, adapter and Earn changes need `MS_OPS`'s threshold (and the timelock, if D12 is timelocked) | **[Safe]** / **[Euler]** |
| Escrows cannot be borrowed from | **[Euler]**: escrows have no oracle |

## Risk automation

The engine watches exit liquidity, volatility, earnings and corporate actions, market sessions, hub concentration, the USDC peg and the risk metrics (R1–R10). It proposes changes to `MS_OPS`. It may itself drive the cap steward key (bounded cap changes, including the daily borrow-cap headroom raise) and, on a page-level alert, the emergency key (tighten only).

| When | What it proposes |
| --- | --- |
| On a breach | Tightening |
| Daily | Target updates; borrow-cap headroom raise through the cap steward; other raises to `MS_OPS` |
| Before earnings or a corporate action | Supply-cap freeze; borrow-LTV cut if needed |

## Listing

1. The engine assigns the name a class, band and hub, after the issuer checks.
2. A deployer key creates the escrow vault from Euler's factory, makes the seed deposit and hands governance to `MS_OPS`.
3. The Oracle Safe calls `configureAssets` and `adminSetPrice`. From then on the keeper pushes the asset, so its price is fresh when the route goes live. `registerBase` needs the asset configured, not a live price.
4. An `MS_OPS` batch:
   - registers the base on the adapter;
   - adds the route and the escrow's resolved-vault entry;
   - sets launch LTVs at half the class ceiling;
   - sets finite launch caps.
5. `MS_OPS` steps it up over time **[Policy]**.

Before each batch, a config-check script verifies:

- routes point to the Poppie adapter;
- wrappers are never resolved vaults;
- escrows come from Euler's factory;
- caps are finite;
- the name's issuer pause schedule is loaded and served to the app and SDK.

There is no on-chain notice period unless D12 is timelocked, in which case each listing waits for the delay. The config-check script and decoded, simulated review of every batch are the protection **[Policy]**.

## Monitoring

In addition to the shared alerts in `docs/Overview.md` ("Monitoring"):

- **Oracle admin:** any threshold, staleness, window or keeper change; any queued call (if D13 is a timelock).
- **Sanctions:** deposits, borrows or receivers on the Chainalysis list (R9).

## Audits

| Track | Scope |
| --- | --- |
| Deployment and configuration | The grant scripts and check script; Safe thresholds; roles on Euler's emergency governor and cap steward; byte-for-byte verification of the oracle and adapter. No new Poppie contract code |
| Off-chain systems | Keeper, corporate-action engine, alerting, pause-window sync to app and SDK |
| Economic | Class and band thresholds; breaker and cap sizing against real weekend, earnings and split gaps |

## Rollout

| Phase | Scope | Gate to next phase |
| --- | --- | --- |
| 0 | Keeper extended from BSC (multiplier and stock-price gates, per-issuer rules, chunking): **prototyped** on an Arbitrum fork against the real xStocks contracts (KEEP-2 to KEEP-20); still to do: live vendor data, a corporate-action feed, an issuer interface, production wiring and state storage, the v2 monitor. Fork test that a third party can liquidate through Enso (liquidate, unwrap, sell, repay). EVK harness and Arbitrum fork tests: stale-price and cap behaviour, Earn accepting the hubs, 300+ LTV entries in one hub, `ProtocolConfig` values. (A real xStocks multiplier change through the router and adapter already passes: `eval/fork/`) | All pass; issuer questions answered; exit route confirmed per name |
| 1 (~100 assets) | Prime hub plus 3 band hubs; both Earn vaults | Check script passes; alerts live |
| 2 (→ 500 assets) | More names; more hubs per band if needed | — |

## Decisions

Shared decisions (D1–D4, D7, D9–D11, D18) are in `docs/Overview.md`. Design-specific:

| ID | Decision | Status |
| --- | --- | --- |
| D5 | Listing | Decided: instant, by `MS_OPS` (waits for the delay if D12 is timelocked) |
| D6 | `adminSetPrice` | Decided: Oracle Safe only, with an on-call signer rota |
| D8 | Issuer pause windows | Decided: off-chain. App and SDK block deposit and withdraw during issuer windows; the issuer's on-chain pause enforces; alerts matched to schedules |
| D12 | Vault governance | Proposed: Euler's `GovernorAccessControlEmergency` as every vault's `governorAdmin`, with an emergency key (tighten only) and `CapRiskSteward` (bounded cap changes). Open: `MS_OPS` instant, or behind Euler's timelocks (≥ 1 day) |
| D13 | Oracle admin | Open: Safe (unbounded, instant) or a timelock proposed by the Oracle Safe (bounded, every admin action delayed) |
| D14 | Keeper slot | Open: one KMS key, or a keeper Safe with Zodiac Roles and several keys |
| D15 | Hub hook slot | Open: Euler's `HookTargetGuardian` for a borrow pause, or leave the slot empty |
| D16 | Origination fee | Proposed: charged by the app and SDK only; unenforced |
| D17 | Sanctions | Proposed: app and SDK screening plus issuer and USDC lists; legal review before launch |

## Known blockers and limitations

Items 1–9 are shared (`docs/Overview.md`). Design-specific:

10. **`MS_OPS` holds all structural power.** It can repoint routes, install hooks and change rates, instantly unless D12 is timelocked. Users must trust its signers.
11. **Single keeper address.** Several processes share one key, which needs careful nonce coordination, unless D14 adds a keeper Safe. A stolen keeper key can pause every asset.
12. **No per-account or per-hour controls on-chain.** Borrowing bursts are bounded only by cap headroom; stolen funds and sanctioned callers can't be frozen or blocked by Poppie (see "Risk management").
13. **The Oracle Safe is unbounded,** unless every admin action is delayed (D13).

## Expectations for integrators

In addition to the shared expectations in `docs/Overview.md`:

- **Risk limits:** set by Poppie's published policy and stock Euler settings, not by Poppie contracts. Borrow caps are kept close to current borrows and raised daily, so large borrows may hit "cap reached".
- **Origination fee:** charged only through Poppie's app and SDK (one extra borrow in the same batch); direct calls pay none.
- **Sanctions:** Poppie screens in its app and SDK; on-chain, only the issuer tokens' and USDC's own lists apply.
- **Pause windows:** Poppie's app and SDK block deposits and withdrawals of a name during its issuer's published pause windows. Direct calls may revert because of the issuer's own pause. Borrowing, repaying and liquidation continue.
- **Changes:** tightening takes effect immediately. Listings, route changes and risk raises are immediate too, unless D12 is timelocked.

## Deferred

Shared deferred items (dividend capture, a Poppie-run liquidator) are in `docs/Overview.md`.

- **Peripheral contracts:** hub and escrow guard hooks (borrow rate limit, sanctions screening, enforced fee, on-chain pause windows), an oracle admin guard, a keeper forwarder and an add-only router governor. That is the peripheral design: `docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`. Any of them can be added to this design later without changing the core.
