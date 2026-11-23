# Poppie v2 on Arbitrum: Design (peripheral-contract)

*Nov 16, 2026. This design is the zero-contract design (`docs/zeroContracts/Design.md`) plus five small Poppie contracts (P1–P5) in slots the core already exposes: vault hooks, the oracle's `admin` and `keeper` slots, and the router's governor. **Everything in the zero-contract design applies unless this document says otherwise**: how it works, asset classes, hubs, issuers, risk metrics, liquidity policy, prices and corporate actions, stock Euler governance, monitoring and decisions D1–D4, D7, D9–D11 and D18. Executive comparison and gap IDs (G1–G12): `docs/Overview.md`.*

## Summary

- **Unchanged:** the audited v1 oracle and adapter, and every stock Euler, Safe and OpenZeppelin contract. Nothing is forked or modified.
- **Added:** five small, immutable Poppie contracts that hold no funds. Each is optional and can be added on its own; P4's keys are managed through P3 when P3 is present, otherwise by the Oracle Safe.

| Contract | Plugs into | Purpose |
| --- | --- | --- |
| P1 hub guard | Each hub's hook | Hourly borrow limit; renewable guardian pause; sanctions screening; enforced origination fee; flash loans off / on / paused |
| P2 escrow guard | Each escrow's hook | Issuer pause windows on-chain; guardian deposit pause; sanctions screening; optional account freeze |
| P3 oracle admin guard | Oracle `admin` | Small price fixes instant, large ones delayed or second-approved |
| P4 keeper forwarder | Oracle `keeper` | Several keeper keys; limits how many assets a keeper can pause |
| P5 router governor | Router `governor` | Listings instant; route overwrites timelocked |

**Label added to those of the zero-contract design:** **[Poppie]** = enforced by a Poppie peripheral contract (P1–P5). New code, to be audited; removable by its governor.

## Risk management

The levers below are added to those of the zero-contract design. Metrics R1–R10 are defined there; this design enforces R2, R7, R8, R9 and R10 with contracts.

### Principles

The zero-contract design's four principles apply. Principle 2 (tightening is fast, loosening slow) and principle 4 ([Policy] is a promise) are unchanged; principles 1 and 3 change, and a fifth is added:

- **Principle 1, losses are bounded by what is set in advance, not by how fast we react.** The Kelp/Aave attacker borrowed about $230M within minutes; a Safe takes minutes to hours to sign. Here the hourly borrow limit (P1) bounds a burst without keeping caps tight, and caps and LTVs bound the rest.
- **Principle 3, repay and liquidation stay open.** No Poppie contract hooks repay or liquidation, and seizure transfers always pass. Only Euler's vault-wide disable stops them.
- **Principle 5, every Poppie contract can be removed.** `MS_OPS` can uninstall a hook; each slot contract has an exit back to a Safe or key. A contract bug costs its protection, never user funds: no Poppie contract holds or moves funds.

### Risk appetite

In this design `L_event` sets the hub guard's hourly borrow limit; caps can be sized to exit depth alone.

### Risk register

| Risk | Levers in this design | What bounds the loss | What remains | Change from zero-contract |
| --- | --- | --- | --- | --- |
| **Unbacked or forged collateral** (stolen issuer minter key, issuer upgrade, bridged token) | No bridged tokens **[Policy]**; supply caps per name and issuer (R1) **[Euler]**; hourly borrow limit per hub (R2) **[Poppie]**; guardian pause on borrows and deposits **[Poppie]**; emergency key **[Euler]** | The smaller of R1 and the borrow limit × time to pause | Up to that bound; the reserve covers it (R3) | Rate limit replaces tight cap headroom; no daily cap raises needed |
| **Wrong price within the oracle's bounds** | Keeper gates (D11) **[Policy]**; breaker and cumulative cap **[v1]**; hourly borrow limit **[Poppie]**; guardian pause | Breaker per name; borrow limit across hubs | A wrong price inside the breaker goes live until the next push or a pause | Same, with the rate limit as the hub-wide bound |
| **Issuer multiplier error** | Keeper's multiplier gate (KEEP-11) **[Policy]** | Price stays at the last good value | Wrapper balances reflect the error | Same |
| **Oracle Safe compromised** | Oracle admin guard (P3): moves within ±X% instant, larger ones delayed or second-approved, all cancellable **[Poppie]** | ±X% of the window reference per delay period; anything larger visible for the delay | Repeated small moves, each alerted; the guardian cancels | **Bounded**, where the zero-contract design is unbounded or fully delayed |
| **Keeper key stolen** | Keeper forwarder (P4): several keys, a pause budget per window, instant revocation by a guardian **[Poppie]**; breaker **[v1]** | Breaker per push; at most N assets paused per window, shared by all keepers | N prices wiped before revocation | Can no longer wipe every price |
| **`MS_OPS` compromised** | Euler's emergency governor (D12), optional timelocks; add-only router governor (P5): listings instant, overwrites delayed **[Poppie]** | Route overwrites visible for the delay | Without a timelock on vault governance, LTVs and hooks change instantly; it can uninstall Poppie's hooks | Router overwrites delayed without delaying listings |
| **Liquidations fail** | Caps sized to exit depth, buffers, discounts, session gating, reserve **[Policy]** | R5 per name | Bad debt above the reserve | Same |
| **Gap through the breaker** | Stale freeze; LTV buffers; `adminSetPrice` through P3 (instant within ±X%, else delayed or second-approved) | LTV buffer | Large gap corrections wait for the delay or the second Safe | Large corrections slower, small ones as fast |
| **Issuer burns from, freezes or pauses an escrow** | Per-issuer caps; alerts; escrow guard enforces published pause windows (P2) **[Poppie]** | R1 for that issuer | Escrow cash overstated after a burn | Pause windows enforced on-chain |
| **Stolen funds or sanctioned users** | Hub and escrow guards screen borrowers, receivers and depositors against Chainalysis's list and Poppie's denylist **[Poppie]**; issuer and USDC lists; optional account freeze (P2, legal decision) | Listed addresses blocked from new positions, also on direct calls | New attackers before listing; fresh addresses; funds can't be seized or returned | **Enforced on-chain**, not just in the app |
| **Lender run** | Kink IRM; Earn allocation; utilization alerts; screening of direct lender deposits (not of Earn depositors, nor of hub share transfers) | Utilization above the kink | — | Same |
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
| Account freeze (optional) | P2 | Denylist key, under policy set by counsel | Instant | A listed account's withdrawals and share transfers out (if `OP_TRANSFER` is hooked), including its sub-accounts via the EVC owner | Its deposits and receipts; its liquidation (seizure passes while `isControlCollateralInProgress`) |
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

### What it costs

- **New audit scope:** five small contracts (about 100–300 lines each, estimated) plus their integration with EVK hooks. The 2026 audit covered only the oracle and adapter.
- **A Poppie hook in the borrow and deposit path.** A bug can block borrowing or deposits until `MS_OPS` uninstalls it, and uninstalling removes its protection. Repay and liquidation are never hooked.
- **Integration:** every borrow must be in an EVC batch with the fee borrow; a direct `borrow` reverts while a fee is set.
- **Gas:** one extra call per hooked operation and per push.
- **More keys:** guardian, scheduler, denylist; each tighten-only.
- **More to explain:** the more Poppie can block, the more it may be expected to block (sanctions, court orders).
- **Time:** contracts must be written, tested on the EVK harness and audited before launch, or added after a zero-contract launch.

### Sanctions

**On-chain, with no Poppie code (as in the zero-contract design):** xStocks tokens and wrappers check Chainalysis's list (`0x40C5…C8fb`); Robinhood's registry blocklist; Circle's USDC blacklist.

**Added by this design:**

- P1 blocks a listed or denylisted account (by EVC owner) from borrowing, and blocks borrowed USDC going to a listed receiver; it screens direct lender `deposit`, `mint` and `skim` into hubs (caller's EVC owner and receiver). P1 sees the Euler Earn vault as the depositor, so Earn depositors aren't screened on-chain by P1. Hub share transfers aren't hooked, so a listed address can still receive shares by transfer.
- P2 screens collateral depositors (caller's EVC owner and receiver). Optional: freeze withdrawals and share transfers out for a listed account, if counsel requires it; liquidation still proceeds.
- The app and SDK still screen first, to fail early with a clear message.

**Still not possible:** seizing or returning funds; blocking repay or liquidation of a listed account; catching attackers before listing; stopping fresh addresses.

Legal review of the account freeze, and of the response to court orders and claims like the one Aave faced over the Kelp funds: POP-55.

## Flash loans and fees

Flash loans of hub USDC are on and free at launch, so third-party liquidators need no capital where the exit is atomic (a DEX pool, or a sale through Enso to Backed). P1's flash-loan policy is off / on / paused: `MS_OPS` turns them off or on, and the guardian pause blocks them while it lasts. P1 charges no flash-loan fee.

- **Origination fee (enforced, D16):** every borrow pays a fee, set per hub (capped on-chain, for example at 100 bps). The batch must contain the user's `hub.borrow(amount, receiver)` and `hub.borrow(fee, feeReceiver)`; P1 records both as per-batch state (borrowed flag, `totalBorrows` before, owed, paid) in plain storage, cleared at the vault status check, which reverts the batch if the fee is short. The fee owed is rounded up for each borrow; any borrow to the fee receiver counts as paid. A borrow reverts (`StatusCheckNotHooked`) if the hub doesn't hook `OP_VAULT_STATUS_CHECK`. The fee becomes part of the user's debt, so a first-time borrower needs no USDC up front, and no Poppie contract holds funds. Borrows of the full available cash are rejected. Integrators must batch every borrow; the SDK does. Liquidation, repay and withdraw pay nothing.

## Issuer pause windows [Poppie]

Issuers pause assets on-chain for scheduled operations. Example: Ondo pauses with reason `ASSET_PAUSED` for 20 minutes (00:52–01:12 UTC, weekdays) to apply its daily dividend share-multiplier update.

- **Schedule:** the back end loads each issuer's pause schedule (status API, or on-chain schedules such as xStocks' `newMultiplierActivationTime`) and serves it to the app and SDK.
- **On-chain:** the scheduler key writes each window (plus a buffer) to the escrow guard (P2) for the issuer's group of escrows (`setEscrow(escrow, group)`). P2 reverts deposit, mint, skim, withdraw and redeem of those names during it, for direct callers too. Liquidation seizure always passes. A window must start now or later and lie within one UTC day; windows are bounded in length (`maxWindowLen`, ≤ 1 day) and in number per group per day (`maxPerDay`); `MS_OPS` can clear them per group per day.
- **App and SDK:** disable deposit and withdraw for that name during a window, with a banner and a typed error, so users fail early.
- **Pricing and notification:** as in the zero-contract design: the keeper skips any name paused on-chain, never pauses the oracle (PAUSE-1), and pages on the second consecutive skip. P2's own windows (escrow deposits and withdrawals blocked) are logged, not paged.

## Contracts Poppie deploys on Arbitrum

Five Poppie peripheral contracts are deployed (P1–P5). They are new, immutable and to be audited; specifications under "Contract specifications". Euler's governance contracts are used as published at the `evk-periphery` pin (audit coverage at that pin: POP-17).

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
| Timelocks | OZ `TimelockController`, via Euler's factory | 1 if P5 is used (its overwrite delay), plus 0 or 2 for D12 | Proposer: `MS_OPS` |
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

**One oracle instance.** One oracle and one adapter handle 500 assets (A7). The blast radius of the admin and keeper slots is now bounded by P3 and P4.

**Exit path.** Each slot can be handed back without upgrading the contract. P3: `transferAdmin`, after P3's longest delay. P4: `setKeeper` through P3, instant to a pre-registered backup keeper, delayed to any other address.

### 2. Poppie peripheral contracts **[Poppie]**

Specifications: "Contract specifications" below. All are immutable, hold no funds, and are configured by roles.

| Contract | Plugs into | Configured by | Hot roles (tighten only) |
| --- | --- | --- | --- |
| P1 hub guard | Each hub's hook slot (`OP_BORROW`, `OP_FLASHLOAN`, `OP_DEPOSIT`, `OP_MINT`, `OP_SKIM`, `OP_VAULT_STATUS_CHECK`) | `MS_OPS`: hub config (borrow limit and window, fee rate, flash-loan policy, `setHub`); separately, the account debt cap (`setDebtCap`) | Guardian (pause borrows and flash loans); denylist key (add addresses) |
| P2 escrow guard | Each escrow's hook slot (`OP_DEPOSIT`, `OP_MINT`, `OP_SKIM`, `OP_WITHDRAW`, `OP_REDEEM`, `OP_TRANSFER` as needed) | `MS_OPS`: escrow-to-issuer-group mapping (`setEscrow`) | Guardian (pause deposits); scheduler (add issuer windows of bounded length); denylist key |
| P3 oracle admin guard | Oracle `admin` | Oracle Safe; delays and the ±X% band set at deployment | Guardian (`pauseAssets`, cancel queued calls) |
| P4 keeper forwarder | Oracle `keeper` | `admin` (P3 or the Oracle Safe; rotatable with `setAdmin`) adds keys, sets the budget and guardian; through P3 these are delayed, tightening included | Guardian (revoke a key) |
| P5 router governor | `EulerRouter` governor | `MS_OPS` adds routes and resolved vaults; a timelock makes any other change | — |

The P1 and P2 owner (`MS_OPS`) can rotate their roles instantly (`setOwner`, `setGuardian`, `setDenylister`, and `setScheduler` on P2).

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
| Keeper keys (several) | Push prices; pause up to N assets per window (shared by all keepers) | P4 **[Poppie]**; breaker, cumulative cap, staleness **[v1]** |
| Guardian key | Pause hub borrows and escrow deposits (renewable); cancel queued oracle admin calls; `pauseAssets`; revoke keeper keys | Tighten only **[Poppie]** |
| Scheduler key | Add issuer pause windows to escrows | Bounded window length and count per group per day **[Poppie]** |
| Denylist key | Add addresses to the denylist | Add only; removal by `MS_OPS` **[Poppie]** |
| Emergency key | Lower caps, lower borrow LTVs, disable a vault | **[Euler]** |
| Cap steward key | Cap changes within a factor | **[Euler]** |
| Deployer key | None after deployment | — |

### Pauses

| Need | Mechanism | Who | Instant | Side effects |
| --- | --- | --- | --- | --- |
| Stop new deposits of a name | P2 guardian pause (extend-only, each ≤ `maxPauseDuration`); or escrow supply cap to current supply | Guardian, emergency key or `MS_OPS` | Yes | Withdrawals and liquidations unaffected (EVK verification: POP-33) |
| Stop new borrowing against a name | Borrow LTV lowered | Emergency key or `MS_OPS` | Yes | At 0, indebted accounts using it freeze |
| Stop new borrowing in a hub | P1 guardian pause (renewable, extend-only, each ≤ `maxPauseDuration`); or borrow cap to current borrows | Guardian, emergency key or `MS_OPS` | Yes | Repay and liquidation continue |
| Limit borrowing speed | P1 hourly borrow limit | Always on | — | Large borrows split across hours |
| Stop pricing a name | Oracle `pauseAssets` through P3 or P4 | Guardian, Oracle Safe, keepers (within budget) | Yes | Wipes the price; recovery needs `adminSetPrice` + push |
| Fix a wrong route | P5 overwrite (timelocked) or `MS_OPS` removing the base on the adapter | `MS_OPS` | Adapter: yes. Router: after the delay | The name is unpriced until re-routed |
| Block a name during issuer pause windows | P2 scheduled windows; app and SDK as well | Scheduler key | Scheduled | Enforced on-chain; liquidations continue |
| Freeze one account | P2 account freeze (optional) | Denylist key | Yes | Its liquidation continues |
| Stop everything on a vault | Hook config: disable all operations | Emergency key or `MS_OPS` | Yes | Blocks repay and liquidation. Catastrophe only; also removes P1 or P2 |

### If an address is compromised

- **Keeper key:** moves prices within the breaker per push; pauses at most N assets per window (a budget shared by all keepers); the guardian revokes it at once. Other keepers keep pushing.
- **Oracle Safe:** moves prices instantly within ±X% of the window reference per delay period; anything larger is queued, alerted and cancellable by the guardian, unless the second Safe approves the queued call.
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
| Keeper pauses ≤ N assets per window | **[Poppie]** P4 |
| Routes can be added only to the Poppie adapter; overwrites delayed | **[Poppie]** P5 |
| Emergency changes can only tighten; cap steward changes bounded | **[Euler]** |
| Borrow LTV ≤ liquidation LTV | **[Euler]** |
| Other vault and Earn changes need `MS_OPS`'s threshold (and the timelock, if chosen) | **[Safe]** / **[Euler]** |
| Escrows cannot be borrowed from | **[Euler]** |

## Contract specifications

Written from scratch; nothing is reused from the `scale` branch, which was a ground-up rebuild. Contracts are added only where they remove a risk that policy can't. Gap IDs (G1–G12) refer to the comparison in `docs/Overview.md`.

### Where a contract can plug in

| Plug-in point | How it works | Verified |
| --- | --- | --- |
| **EVK vault hook** | Each vault has one `hookTarget` and a bitmask of hooked operations (`OP_DEPOSIT` … `OP_VAULT_STATUS_CHECK`). Before a hooked operation, EVK calls the target with the original calldata plus the authenticated caller (20 bytes) appended. If the target reverts, the operation reverts. Operations not in the mask never call it | EVK `422bf24`, `Base.sol` `invokeHookTarget`, `Constants.sol` |
| **Vault status check hook** | `OP_VAULT_STATUS_CHECK` runs at the end of every EVC batch that touched the vault, after all operations. A hook here sees the batch's final state | Same |
| **Vault views from a hook** | During a hooked operation the vault is locked against reentry, but the hook target is exempt for view functions (`nonReentrantView`). So a hook can read `totalBorrows`, `cash` and caps | `Base.sol:61-75` |
| **Oracle `admin` and `keeper` slots** | Each slot holds one address, which can be a contract. That contract then has every power of the slot | `PoppieEulerOracle.sol` |
| **Router `governor`** | One address; can be a contract | `EulerRouter` |
| **EVC batch** | A user batch can include calls to any contract; checks run once, at the end | EVC |

**One hook target per vault.** All hub logic must live in one contract, and all escrow logic in one. P1 therefore replaces Euler's `HookTargetGuardian`, an option in the zero-contract design.

### Rules every contract must follow

1. **Never block repay or liquidation.** `OP_REPAY`, `OP_REPAY_WITH_SHARES` and `OP_LIQUIDATE` are never hooked. A status-check hook passes when no borrow happened in the batch. On escrows, `OP_TRANSFER` passes while `evc.isControlCollateralInProgress()` (liquidation seizure).
2. **No custody.** No contract holds user funds or can move them.
3. **No upgrades.** Immutable code; parameters only through roles.
4. **`MS_OPS` can always remove a hook** (`setHookConfig`). A buggy hook is fixed by uninstalling it, at the cost of losing its protection. Slot holders have an exit back to a Safe or key (see "Exit path" under Governance).
5. **Bounded roles:** hot keys can only tighten.


### P1. Hub guard (hook on every hub)

Hooked operations: `OP_BORROW`, `OP_FLASHLOAN`, `OP_DEPOSIT`, `OP_MINT`, `OP_SKIM`, `OP_VAULT_STATUS_CHECK`.

| Feature | Behaviour | Closes |
| --- | --- | --- |
| **Borrow rate limit** | On `OP_BORROW`, records the hub's `totalBorrows` before the batch's first borrow (per-batch state in plain storage, cleared at the status check). On the status check, if a borrow happened, adds the batch's net borrows (the change in `totalBorrows` across the batch, so repays in the same batch net off) to the current window's total and requires it ≤ the hub's limit. The limit is per fixed window; the window length (non-zero) and the limit (in asset units, for example $X per hour) are set per hub. Batches with no borrow always pass. A borrow reverts (`StatusCheckNotHooked`) if `OP_VAULT_STATUS_CHECK` isn't hooked | G1 |
| **Guardian pause** | A guardian key can pause borrows and flash loans for a set time, renewable by the guardian. A pause can only extend an existing one, and each is bounded by the immutable `maxPauseDuration` (≤ 2³²−1 s). `MS_OPS` can unpause | G2 |
| **Sanctions screening** | On `OP_BORROW`: the account's EVC owner and the `receiver` must not be on Chainalysis's list or Poppie's denylist. On `OP_DEPOSIT`, `OP_MINT` and `OP_SKIM` (lenders): the same for the caller's EVC owner and the `receiver` | G7 |
| **Origination fee** | Each batch with a borrow must also borrow `fee = amount × rate` to the hub's fee receiver. On `OP_BORROW`, the hook adds to "owed" (rounded up for each borrow) or "paid" (any borrow to the fee receiver) in per-batch storage. The status check requires paid ≥ owed. Borrows of `type(uint256).max` ("all cash") are rejected | G9 |
| **Flash-loan policy** | Off / on / paused; no flash-loan fee | G10 |
| **Account debt cap** (optional) | Debt of each borrowing account (sub-account, via `debtOf`) ≤ a set amount, checked at the status check only for accounts that borrowed in that batch. Not per EVC owner | G11 |

State: per hub, the window length and start, the net borrows counted in the window, the limit, the fee rate, the flash mode, the pause expiry; separately, the debt cap (`debtCap[hub]`). Per batch, in plain storage cleared at the status check: the borrowed flag, the borrows before, owed and paid.

### P2. Escrow guard (hook on every escrow)

Hooked operations: `OP_DEPOSIT`, `OP_MINT`, `OP_SKIM`, `OP_WITHDRAW`, `OP_REDEEM`, `OP_TRANSFER` (as needed).

| Feature | Behaviour | Closes |
| --- | --- | --- |
| **Scheduled pause windows** | Windows are per issuer group: `MS_OPS` maps escrows to groups (`setEscrow(escrow, group)`). Deposit, mint, skim, withdraw and redeem revert during the group's published windows (for example Backed's multiplier activations), set by a scheduler key that can only add windows. A window must start now or later, lie within one UTC day (no crossing midnight), be at most `maxWindowLen` (≤ 1 day) long, and there can be at most `maxPerDay` per group per day. `MS_OPS` clears windows per group per day. An unconfigured escrow rejects inflows; windows never block its exits. Transfers during liquidation always pass | G8 |
| **Sanctions screening** | On deposit, mint and skim: the caller's EVC owner and the `receiver` are screened. Mostly redundant for xStocks, whose token already screens | G7 |
| **Account freeze** (optional, legal decision) | Withdrawals, and share transfers out when `OP_TRANSFER` is hooked, blocked for an account the denylist key freezes, for example under a court order; covers its sub-accounts via the EVC owner. Frozen accounts can still deposit and receive. Liquidation seizure passes while `isControlCollateralInProgress` | G7 |
| **Guardian deposit pause** | Like P1 (extend-only, each ≤ `maxPauseDuration`), for collateral inflows | G1, G2 |

### P3. Oracle admin guard (in the oracle `admin` slot)

The Oracle Safe calls the guard, which calls the oracle.

| Call | Instant | Delayed |
| --- | --- | --- |
| `pauseAssets` | Yes, also by a guardian key | — |
| `adminSetPrice` | If within ±X% of the asset's window reference: the last price (or the last price before a pause, which the guard records), fixed when an instant write starts a window (a delayed or approved write also resets it to its own price) and kept for `delay`. So instant moves can't walk past ±X% within one window. A configured, unpaused, never-priced asset can be seeded instantly at any price | Otherwise. Once queued by the Safe, the second Safe can land it with `approveQueued` at any time before expiry (only for `adminSetPrice` to the oracle) |
| `setAssetThresholds`, `setMaxPriceAge`, `setAssetMaxPriceAge` | If tightening | If loosening (including staleness disabled) |
| `setAnchorWindow`, `configureAssets` | `configureAssets` (it moves no price) | `setAnchorWindow` |
| `setKeeper` | To a pre-registered backup keeper | Any other address |
| `transferAdmin` | — | Long delay |

A queued call can be executed during [eta, eta + delay]; then it expires and may be re-submitted. The guardian can cancel any queued call; the second Safe can cancel any except a queued `setSecondSafe`, which only the guardian can cancel. Calls not aimed at the oracle (for example to P4, or P3's own setters) are always delayed. `acceptAdmin` can't be submitted; `acceptOracleAdmin()` is permissionless.

Roles: `setSafe`, `setSecondSafe` and `setBackupKeeper` run only through P3's own submit-then-execute queue, so they are delayed. `setGuardian` is instant and Oracle Safe only. The second Safe cannot appoint the guardian, so it cannot take the role and cancel its own queued replacement (POP-37). `pauseAssets` by the Safe or the guardian records the pre-pause price.

Closes **G3**, Poppie's largest unbounded risk. Cost: gaps beyond the breaker wait for the delay or the second approval.

### P4. Keeper forwarder (in the oracle `keeper` slot)

- Several keeper keys may push; each runs its own process, so there's no shared-nonce coordination.
- `pauseAssets` by keepers is limited to N assets per fixed window of configurable length, a budget shared by all keepers. Today a stolen keeper key can pause every asset and wipe every price.
- `admin` is P3 or the Oracle Safe, and can be rotated (`setAdmin`). Through P3, adding keys and changing the budget or guardian are delayed, including tightening the budget. A guardian revokes a key instantly; so can the admin, instantly only if it is the Oracle Safe directly (through P3, removal is delayed like any other P4 call).

Closes **G4**. Tighter than the zero-contract Safe-plus-Roles keeper (D14), which needs no new audit but cannot limit pauses.

### P5. Add-only router governor (in the router `governor` slot)

- `MS_OPS` adds routes instantly (`addRoute`), only to the Poppie adapter, and only for bases registered on the adapter.
- `MS_OPS` adds an escrow's resolved-vault entry instantly (`addResolvedVault(vault)`), only for an escrow-factory proxy whose asset already routes to the Poppie adapter.
- Neither ever shadows an existing route or resolved vault.
- Overwrites, deletions, the fallback oracle and `transferGovernance` go through the timelock's `execute`. `opsSafe` and `timelock` are immutable (no role setters).

Closes **G6** without delaying listings, unlike the zero-contract timelock.

### Not needed as contracts

- **Emergency tightening and bounded cap changes:** Euler's `GovernorAccessControlEmergency` and `CapRiskSteward`, used in both designs (G2). `MS_OPS` itself is bounded only by Euler's timelocks (G5, D12).
- **Liquidator:** none at launch (D9). It would add no buyers.
- **Dividend capture:** not at launch (D4).

### Suggested order

1. **P3 oracle admin guard.** The only bound on a compromised Oracle Safe.
2. **P1 hub guard,** with the rate limit, guardian pause and sanctions first; the fee can be switched on later.
3. **P4 keeper forwarder.**
4. **P5 router governor** and **P2 escrow guard.**

Poppie can adopt any subset and keep the rest of the zero-contract design. Only P4 relates to another contract: with P3, its keys are added through P3.

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
   - adds the route through P5 (`addRoute`; instant; only to the Poppie adapter), then the escrow's resolved-vault entry (`addResolvedVault`; instant; needs the asset's route in place);
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

In addition to the alerts in the zero-contract design (its "Oracle admin" alert is replaced by the first item below):

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
| 0 | Keeper extended from BSC (multiplier and stock-price gates, per-issuer rules, chunking): **prototyped** on an Arbitrum fork against the real xStocks contracts (KEEP-2 to KEEP-22); remaining keeper work: milestone D. Fork test that a third party can liquidate through Enso (liquidate, unwrap, sell, repay): POP-68. EVK harness and Arbitrum fork tests of stale-price and cap behaviour: POP-33. Earn accepting the hubs, 300+ LTV entries in one hub, and the `ProtocolConfig` values are checked (`test-peripheral/fork/EulerForkChecks.t.sol`). (A real xStocks multiplier change through the router and adapter already passes: `eval/fork/`). P1–P5: **written**, with unit and invariant tests on mocks (`MockVault`, `MockEVC`) and 5 Arbitrum fork tests pinned at block 525105000 (P1 against the real Chainalysis list and a real EVC deployed on the fork, with a mock hub; P3 with the audited oracle and adapter pricing a real xStock), plus 9 interface-only Euler fork checks (`test-peripheral/fork/EulerForkChecks.t.sol`; P1 installed as the hook of a hub from the canonical factory). EVK integration (EVK isn't in the repo yet): POP-33. Audit: POP-17 | All pass; audit findings closed; issuer questions answered; exit route confirmed per name |
| 1 (~100 assets) | Prime hub plus 3 band hubs; both Earn vaults | Check script passes; alerts live |
| 2 (→ 500 assets) | More names; more hubs per band if needed | — |

Alternative (recommended in `docs/Overview.md`): launch phase 1 as the zero-contract design and add P1–P5 as each passes audit: P3 and P1 first, since they bound the largest risks.

## Decisions

These replace D5, D6, D8 and D13–D17 of the zero-contract design and add D19. The rest, including D12 (vault governance), apply unchanged.

| ID | Decision | Status |
| --- | --- | --- |
| D5 | Listing | Instant, by `MS_OPS` through P5 (add-only); overwrites timelocked |
| D6 | `adminSetPrice` | Oracle Safe through P3: within ±X% instant; larger moves delayed or second-approved; on-call signer rota |
| D8 | Issuer pause windows | On-chain through P2, plus app and SDK; alerts matched to schedules |
| D13 | Oracle admin | Decided: P3, with second-Safe approval of queued `adminSetPrice`. Instant band ±X% and delay: POP-44 |
| D14 | Keeper slot | Open: POP-44 |
| D15 | Hub and escrow hooks | Open: POP-44 |
| D16 | Origination fee | Open: POP-44 |
| D17 | Sanctions | Open: POP-55 |
| D19 | Contract set | Open: POP-50 |

## Known blockers and limitations

Items 1–6 of the zero-contract design apply. Items 7–9 apply with these changes:

7. **Gaps beyond the breaker:** a correction within ±X% is instant through P3; larger ones wait for P3's delay or a second Safe's approval, so the name stays stale longer.
8. **`MS_OPS` signing load:** lower, since P1 removes the daily borrow-cap raises; it still signs every other risk change and corporate action.
9. **Single admin and keeper for all names:** still one oracle, but the admin and keeper slots are bounded by P3 and P4.

Items 10–13 there are replaced by:

10. **`MS_OPS` holds vault power.** It can change any vault setting (instantly unless D12 is timelocked) and uninstall P1 and P2. Route overwrites wait for P5's delay. Users must trust its signers.
11. **Keeper and oracle admin are bounded, not removed.** A stolen keeper key moves prices within the breaker and pauses up to N assets per window; a compromised Oracle Safe moves prices within ±X% of the window reference per delay period.
12. **New audit scope and hook liveness.** P1–P5 are new code. A bug in P1 or P2 can block borrowing or deposits until uninstalled; a bug in P3 or P4 can block admin calls or pushes until the slot is moved. Repay and liquidation are never hooked.
13. **No seizure and no pre-listing detection.** Stolen funds can't be frozen before an address is listed, and no contract can seize or return funds.

## Expectations for integrators

In addition to the zero-contract design's "Stale prices" expectation:

- **Price bounds:** prices are bounded per push and per window. A wrong push within those bounds goes live; an admin price write goes live at once only within ±X% of the window reference (P3).
- **Pauses:** a vault-wide disable blocks repay and liquidation while active and lasts until reversed. Guardian pauses (P1, P2) last a set time and can be renewed.
- **Risk limits:** set by Poppie's published policy, stock Euler settings and P1–P5. New borrowing per hub is limited per hour; a large borrow may need to wait for the next window.
- **Borrowing:** every borrow must be an EVC batch that also borrows the fee to the hub's fee receiver; a direct `borrow` reverts while a fee is set. Borrowing the full available cash is rejected.
- **Sanctions:** borrows, borrow receivers and direct `deposit`, `mint` and `skim` by or to listed or denylisted addresses revert on-chain (P1, P2). Deposits through Euler Earn are screened only on the Earn vault, not its depositors, and hub share transfers aren't screened. Repay and liquidation of such accounts still work.
- **Pause windows:** deposits and withdrawals of a name revert during its issuer's published pause windows (P2), for direct calls too. Borrowing, repaying and liquidation continue.
- **Changes:** tightening takes effect immediately. Listings are immediate; route overwrites wait for P5's delay; risk raises are immediate unless D12 is timelocked; large oracle admin price writes wait for P3's delay.

Open items: tracked in Linear, project Euler v2 (Poppie).
