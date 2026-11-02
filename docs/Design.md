# Poppie on Arbitrum with the v1 contracts: evaluation and refactor plan

*For an agent with access to the v1 code (`v1-bsc` tag). Goal: decide which potential blockers are real, then produce a build plan. The v2 draft (custom contracts, `docs/` on `scale`) is tabled; use it only as reference for requirements and for the Euler pins.*

## 1. Goal and constraints

**Goal:** scale Poppie from the BSC deployment to a multi-issuer market on Arbitrum (Euler V2), up to ~500 tokenized-equity collaterals (Ondo-style, xStocks, Reality, Dinari and similar), **without changing the audited v1 contracts** (`PoppieEulerOracle`, `PoppieEulerAdapter`). Scale, risk and issuer handling move to back-end systems plus stock Euler / Safe components.

**Hard rules for the agent:**
- Do not modify v1 `src/`. Recompiling the same source with the same settings is allowed.
- New code is allowed only in tests, scripts and scratch evaluation files. Flag any finding that would require new on-chain logic.
- Never run anything against a live network. Local, anvil or fork only.
- Do not change `main`. Confirm with a human which branch to work on before committing.
- Poppie is its own price oracle by design. Do not propose third-party price feeds.
- Cite evidence as `file:line` (v1 code, Euler libs) or a URL (issuer docs, explorers).

## 2. Target architecture (what is being evaluated)

| Concern | v1-as-is approach |
|---|---|
| Prices | v1 `PoppieEulerOracle` + `PoppieEulerAdapter`, redeployed unchanged. Keeper pushes on deviation plus heartbeat, chunked and pre-simulated. Possibly several oracle/adapter instances (per issuer or band) |
| Vaults | Stock EVK hubs (Prime + bands) and escrow vaults; `CFG_DONT_SOCIALIZE_DEBT`; loss reserve Safe |
| Governance | evk-periphery `GovernorAccessControlEmergency` (instant tightening), `CapRiskSteward` (bounded cap raises), Safe for loosening, `TimelockController` for structural changes |
| Pauses / closed deposits | EVK native op-disable (hooked op with `hookTarget = 0`) and supply caps frozen at current supply |
| Routing | Stock EulerRouter; governed by Safe (instant listing, trusted) or timelock (48h batched listing) |
| Rebasing tokens | Issuer-provided non-rebasing wrapper, or an unmodified OpenZeppelin `ERC4626`. The **wrapper share** is the oracle base; keeper prices it as equity price × stock per share |
| Stablecoin dividends | Issuer-side redirection/exclusion, issuer accumulating variant, or disclosed leakage |
| Closed markets | Per-asset policy: (A) let price go stale (freeze) or (B) heartbeat at last close with pre-close borrow-LTV cuts and supply-cap freeze |
| Dropped | Origination fee, three-state pricing, `K_CONFIRM`, on-chain bounds on LTV raises, add-only routes |

## 3. Investigation checklist

For each item record: **status** (see §4), evidence, impact at 500 assets, and the workaround if it is an issue. Write a test where the answer depends on runtime behaviour.

### A. v1 oracle and adapter (read the code, write tests)

| ID | Question | How to verify | If it's an issue |
|---|---|---|---|
| A1 | Does one bad entry (breaker trip, paused, unknown asset, zero price) revert the whole `keeperPushPrices` batch? | Read the loop; test a 3-asset batch with one failing entry | Keeper simulates every chunk and drops failing assets. Not a blocker; specify in keeper design |
| A2 | Circuit breaker and cumulative deviation cap: per-asset or global? Settable range? Can thresholds be wide (≥ 30%)? Admin-only? | Read setters and bounds; test boundary values | Count admin ops per Monday open / earnings gap at 500 assets. Blocker only if thresholds can't be sized per class |
| A3 | How does the anchor window behave after a gap (weekend, halt, stale period)? Does a valid push after staleness pass both guards against the stale `lastPrice` / old anchor? | Test: push, warp > `maxPriceAge` and > `anchorWindow`, push within and beyond thresholds | Determines whether "stop pushing → auto-freeze → resume" works without admin. Critical for closed-market policy A |
| A4 | Pause: confirm it zeroes price state and requires `adminSetPrice` + keeper push to recover. Can `adminSetPrice` / pause be batched? | Read + test | Restrict oracle pause to emergencies; routine halts use staleness and EVK-side controls |
| A5 | `maxPriceAge`: global + per-asset override, `== 0` disable path, boundary (`>` vs `>=`) | Read + test | Needed for halt-prone names and heartbeat design |
| A6 | Roles: single keeper or many? Single admin with two-step transfer? Can admin be a contract (Safe, timelock)? Exact list of instant admin powers | Read access control | Map to Safe + Zodiac Roles split. Note that the admin must be instant (recovery), so it holds instant price power |
| A7 | Scale: storage slots per asset, any loop over all assets (config, views, rotation), id/index type widths, max asset count | Read; gas-test pushes of 100 / 250 / 500 assets; config of 500 assets | Chunking or multiple instances. Blocker only if an O(n) path is unavoidable on push or read |
| A8 | Chain assumptions: `block.number` use (Arbitrum returns the L1 block), `chainid`, hard-coded addresses (USDT, `address(840)`), compiler and `evm_version` used for the audited build | Grep + read `foundry.toml` at the tag | Any `block.number` logic that changes meaning is a blocker requiring a code change; flag it |
| A9 | Adapter: does `getQuotes` return bid == ask == mid? Revert propagation on stale/paused? Quote restricted to USD? Can the base be any registered address (e.g. an ERC4626 share)? | Read + test | Confirms wrapper-share pricing works unchanged |
| A10 | Decimals: `registerBase` cross-check and the ≤ 18 bound. Does a wrapper with `decimalsOffset > 0` exceed it? | Read + test with an 18-dec underlying | Forces `decimalsOffset = 0` on any OZ wrapper |
| A11 | Can several oracle/adapter pairs coexist (no singleton or global-state assumption)? | Read constructors and storage | Enables per-issuer or per-band isolation |
| A12 | Audit report (`audit/`): any finding or assumption that depends on BSC, single-issuer use or the BSC asset count | Read report | List items needing a delta review |

### B. Stock Euler components at the pinned commits

Use the pins in the `scale` branch README (EVC `a7d3c29`, EVK `422bf24`, evk-periphery `96b83f8`, Earn `b2fd6e6`). Euler contracts are used at their canonical Arbitrum addresses; verify against `euler-interfaces` where relevant.

| ID | Question | How to verify | If it's an issue |
|---|---|---|---|
| B1 | Does `GovernorAccessControlEmergency` exist at `96b83f8`? Exactly what can each emergency role do (lower borrow LTV only? liquidation LTV? ramps? lower caps? which ops can the hook role disable)? | Read source; local test | If missing at the pin: newer periphery commit (check gitlink compatibility) or Safe-only tightening |
| B2 | Does `CapRiskSteward` exist at the pin? Limits (max factor, period), IRM-change behaviour | Read source | If missing: cap raises via Safe only |
| B3 | EVK: an op hooked with `hookTarget = address(0)` reverts (disabled). Which ops can be disabled this way? | Read EVK `Base`/hook code; test | Pause design depends on this |
| B4 | EVK has no token-recovery path; confirm `skim` semantics with an unaccounted balance | Read EVK | Confirms stablecoin dividends and positive rebases can't stay in a plain escrow |
| B5 | Supply cap set at or below current supply: blocks deposit/mint/skim, allows withdraw, redeem, transfer and liquidation seizure? AmountCap rounding | Test on local EVK | Closed-deposit design depends on this |
| B6 | When one collateral's price reverts: which ops fail (borrow, withdraw, transfer, liquidate) and which still work (repay, deposit of other collateral)? | Test on local EVK with a reverting oracle | Defines the freeze scope for closed-market policy A |
| B7 | EulerRouter: escrow → wrapper as a resolved vault, wrapper share priced directly by the adapter. Works for EVK account checks and liquidation? | Test via router | Confirms the wrapper-share pricing path |
| B8 | Can Governor access control restrict EulerRouter `govSetConfig` to unset routes? (Expected: no; selector-level only) | Read | Choose instant-trusted vs timelocked listing (human decision D5) |
| B9 | Scale: hub with 500 LTV entries (`setLTV`, `LTVList()`, lens), account checks with 10 collaterals, Earn strategy queue limit | Gas tests on local EVK | Reuse v2 scale-test ideas (§8 of `V2_PLAN.md`) |
| B10 | Arbitrum `ProtocolConfig` interest-fee range and Kink IRM rate floor: enough to replace the origination fee's revenue? | Read on-chain config via fork | Feeds human decision D2 |

### C. Issuer mechanics (external research; may need a human)

For each issuer (Ondo GM, xStocks, Reality, Dinari, others in scope), fill one row. Use issuer docs and verified contracts; if not yet on Arbitrum, use another EVM deployment and mark it.

| Field | Why it matters |
|---|---|
| Balance model: multiplier (static balances) or rebasing `balanceOf` | Rebasing ⇒ wrapper required |
| Transfer exactness (does `transfer(x)` move exactly `x`, or `x − 1` wei?) | OZ `ERC4626` credits the requested amount; drift must be tested |
| Split handling (multiplier change, rebase, token migration) | Keeper per-share ratio and corporate-action runbook |
| Dividend delivery: reinvested rebase, stablecoin push, claim-based | Stablecoin push/claim ⇒ stuck in any vault without issuer cooperation |
| Can addresses be excluded from or redirected for dividends? | Main workaround for stablecoin dividends |
| Issuer-provided non-rebasing / accumulating wrapper? Audited? | Preferred over a Poppie-deployed wrapper |
| Admin powers: pause, freeze, seize, allowlist | Escrow and wrapper addresses may need allowlisting; freeze blocks withdrawals |
| Arbitrum addresses and liquidity / exit depth | Listability |

C-extra: if any issuer needs a wrapper and has none, test an unmodified OZ `ERC4626` (constructor only, `decimalsOffset = 0`, seed deposit) against a mock of that issuer's token: pro-rata positive and negative rebases, 1-wei transfer drift, first-depositor inflation with the seed.

### D. Human decisions (frame them with the findings; don't decide)

| ID | Decision |
|---|---|
| D1 | Closed-market policy per class: A (freeze) or B (heartbeat at last close + LTV cut + supply-cap freeze). Inputs: A3, B5, B6 |
| D2 | Drop the origination fee and rely on interest fee, rate floor and Earn performance fee. Input: B10 |
| D3 | Allow one unmodified OZ `ERC4626` as the only non-audited deployment, or require issuer wrappers. Input: C |
| D4 | Stablecoin-dividend issuers: list with issuer redirection, list with disclosed leakage, or don't list. Input: C |
| D5 | Listing: instant via Safe (trusted route overwrites) or 48h timelocked batches. Input: B8 |
| D6 | Delegate `adminSetPrice` to an ops signer via Zodiac Roles (faster recovery, weaker guard), or keep it on the Safe. Input: A2, A4, A6 |
| D7 | One oracle instance or several (per issuer or band). Input: A7, A11 |

## 4. Status values

- **Not an issue:** verified; no action.
- **Issue, workaround:** real, handled by back-end, config or stock components. State the workaround.
- **Blocker:** cannot be solved without changing audited code or adding new on-chain logic. State the minimum change.
- **Needs external info:** depends on issuer data not available to the agent.
- **Needs human:** depends on a D-decision.

## 5. Deliverables

1. **Findings report** (`EVAL_FINDINGS.md`): one row per ID (A1–A12, B1–B10, C per issuer), with status, evidence, impact at 500 assets and workaround. Blockers first.
2. **Tests** backing every runtime claim, in a scratch test directory, runnable with `forge test`.
3. **Decision brief:** D1–D7, each with options, the findings that bear on it and a recommendation.
4. **Build plan** (after decisions, or with stated assumptions), covering:
   - Deployment scripts: oracle/adapter redeploy, hubs, escrows, wrappers (if any), router, governors, timelock, Earn, reserve Safe, role wiring, config-check script.
   - Listing batch format for ~500 assets (Safe Transaction Builder JSON, diffable).
   - Back-end specs: keeper (deviation + heartbeat, chunking, pre-simulation, per-share pricing), corporate-action engine (pre-event borrow-LTV cut, reopen rule), risk engine (raise limits enforced in signing policy, since the chain no longer enforces them), closed-market scheduler, dividend reconciliation, monitoring and alerts.
   - Delta-review scope for the audited contracts on Arbitrum (from A8, A12).
   - Scale and fork tests (from A7, B9).

## 6. Suggested order

1. A8, A12, B1, B2 (anything that could force a code change or a different pin).
2. A1–A7, A9–A11 with tests.
3. B3–B10 on the local EVK harness.
4. C research per issuer, then the C-extra wrapper test if needed.
5. Findings report and decision brief; stop for human decisions.
6. Build plan.