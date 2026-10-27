# Poppie v2 plan (Arbitrum, Euler V2)

*Plan approved on Oct 26 2026 and updated on Oct 27 2026 with the open-question resolutions (see `docs/OPEN_QUESTIONS.md`), on top of `docs/CONTRACT_SPEC.md` and `docs/ARCHITECTURE.md`. Where it differs, this plan wins for v2 design intent.*

*Section numbers (§0-§9, §2a) are cited by the Linear tickets in the "Euler v2" project. Do not renumber.*

## §0 Repo

* Tag current `main` as `v1-bsc`; build v2 on the `scale` branch (`main` is never changed; every PR targets `scale`); `main` matches BSC production until Arbitrum launch.
* Replace `src/`, `test/`, `script/` in place. v1 stays at the tag.
* `foundry.toml`: pin solc to the version Euler's Arbitrum deployment used (read from the verified contracts); `evm_version = cancun`.
* Submodules: `ethereum-vault-connector`, `euler-vault-kit`, `euler-price-oracle`, `evk-periphery`, `euler-earn`, each pinned to Euler's Arbitrum commits. Tidy the empty `lib/euler-price-oracle` directory; initialise existing submodules.
* Layout: `src/{oracle,wrapper,hooks,fee,governance,access,interfaces}`.
* `PoppieAccessControl`: shared base. Timelock is `DEFAULT_ADMIN`. MS_OPS can revoke `K_*` roles but not grant them.

## §1 `PoppieEulerOracle` v2

* Storage: two slots per asset. Hot slot (read/written every push): `lastPrice`, `lastTs`, `pendingCount`, `pendingDir`, `paused`, `priceClass`, `decimals`, `listed`, `id`. Pending slot: `pendingPrice`, `pendingTs`, written only while a move is pending. One global slot: `maxPriceAge`, `n`, `minPendingSpacing`, `hBps` per price class.
* Price class is separate from the steward's risk class; changes go through the timelock.
* `listAssets(tokens[], classes[])`: MS_OPS, add-only. **Underlying tokens only, never wrappers.** Assigns a `uint16` id. Reads `decimals()` of the underlying token, must be <= 18.
* Two push formats sharing one internal `_push`: spec's `keeperPushPrices(address[], uint128[])` and packed `keeperPushPacked(bytes)`, 14 bytes per asset (`uint16 id | uint96 price`).
* State machine as in `CONTRACT_SPEC.md §3.1`, plus: while `L == 0` a push is always pending and only `K_CONFIRM` can take it live; a push counts toward `n` only if at least `minPendingSpacing` has passed since the last pending push; `confirm` reverts while paused; new `confirmBatch`; setter enforces `n >= 2`.
* Views: `state(asset)`; `getQuoteData(asset)` returning state, `L`, `P`, `h`, decimals in one call; batch views for monitoring.

## §2 `PoppieEulerAdapter` v2

* Immutable, no admin. Quote must be USD (`0x...0348`); base must be a listed token.
* Three-state table per `CONTRACT_SPEC.md §3.2`: bid rounds down, ask rounds up; mid reverts `PriceUnavailable` (Closed) or `PriceUnconfirmed`.
* The router reaches the adapter via escrow -> wrapper (if any) -> token resolved vaults.

## §2a `PoppieBalanceWrapper` and `PoppieWrapperFactory`

* Immutable, ERC-4626-style. One wrapper per balance-changing token (xStocks; Reality on splits), deployed by the factory.
* Share count never changes on its own; `convertToAssets` follows the wrapper's own `balanceOf(token)`, so positive and negative rebases are shared pro rata.
* Deposits mint shares from the balance actually received. Factory makes a seed deposit at creation and the wrapper uses a virtual share offset (no first-depositor inflation). No skim: donated tokens raise every share's value.
* Factory keeps `isWrapper` and `wrapperOf[token]`; one wrapper per token.
* Dividend-paying tokens (issuer mechanism `distributing`) are wrapped too. The wrapper has a permissionless `sweep(token)` for any token other than its underlying; it always sends to a recipient stored in the factory (the reserve Safe), which only MS_ADMIN can change, via the timelock. Depositors forgo dividends while deposited (disclosed at deposit). Flagged for review (Q2).

## §3 `PoppieFeeRouter` and `PoppieHubHook`

* Hubs registered through the timelock; the hook rejects calls from any vault that is not a registered hub.
* `borrow`: receiver must be the router, amount must not be `max`, borrows not paused; then `recordPending`.
* Status check requires `pendingTotal == 0`. Flash loans always revert. Liquidations revert only while a liquidation pause is active.
* Router: pending amounts in transient storage; non-upgradeable; `forward` must be called via the EVC and resolves the account with `getCurrentOnBehalfOfAccount`; fee rounds up; MS_OPS `sweep` for mistaken transfers. Invariant: no transaction changes the router's balance. The fee goes to `hub.feeReceiver()`; there is no `setTreasury`; a zero fee receiver makes borrows revert.
* Pauses: `K_GUARD` borrow pause <= 24h per call with **no cooldown** (it can re-pause as soon as one expires; the control is MS_OPS revoking the key, plus alerts); MS_OPS liquidation pause <= 6h per call, and can be repeated back to back.

## §4 `PoppieEscrowHook`

* `deposit`, `mint`, `skim`, `transfer` revert when the asset is Closed or deposits are paused. The deposit pause (`K_GUARD`) follows the same rules as the borrow pause: <= 24h per call, no cooldown.
* Resolves the vault's asset first: if it is a wrapper, check the wrapper's underlying token.
* Transfers allowed while `evc.isControlCollateralInProgress()`, so liquidations can seize during a deposit pause.
* Escrow vaults are non-upgradeable factory proxies. Creation order: seed deposit -> set hook config -> hand governance to the Governor. A deployer key does this before the MS_OPS batch (see §7; flagged for review, Q1).

## §5 `PoppieRouterGovernor`

* `addRoute(token)`: add-only, token must be approved.
* `addWrapper(wrapper)`: add-only; must come from the factory, wrap an approved token, not already registered; registers wrapper -> token as a resolved vault.
* `addResolvedVault(escrow)`: add-only; escrow must be a non-upgradeable factory proxy, no oracle and no unit of account, Poppie Governor as `governorAdmin`, expected hook config, and `asset()` is either an approved token or a registered wrapper.
* `setApprovedToken` and `execute` go through the timelock.

## §6 `PoppieRiskSteward`

* Stored per asset: token -> wrapper (if any) -> escrow vault; risk class and band hub; cap ceilings; per (asset, hub), the liquidation-LTV baseline in force before the current chain of cuts (for ramp cancel). Global: hub list and each hub's band.
* Blue-chip sync: every blue-chip change applies to all hubs atomically.
* Ramps: pass the remaining ramp time on every `setLTV` so an active liquidation-LTV ramp is never cut short. Caps use EVK AmountCap encoding (raw 0 = unlimited; "zero" is raw 1).
* Tightening: lowering borrow LTVs and caps is instant and batched, no global rate limit. Liquidation-LTV cuts keep every limit: <= 5 pts per call, ramp >= 72h, once per asset per hub per 24h. The "<= 10 assets per rolling 24h" budget is removed; MS_OPS ramp cancel is the defence.
* MS_OPS override (replaces the earlier undo / `restore`): MS_OPS can set borrow LTVs and caps anywhere up to the class LTV ceilings and each asset's cap ceiling, in batches, without the weekly limit. The borrow LTV still cannot exceed the liquidation LTV and the gap rule still applies; the override does not raise liquidation LTV except through ramp cancel.
* Ramp cancel (MS_OPS, batched): for a liquidation-LTV cut still ramping, restore the liquidation LTV in force before the first cut of the current chain (steward-recorded baseline), never above the class ceiling. Also cancels demotion ramps.
* Loosening: `raiseLTV` <= 3 pts, once per asset per 7 days, within ceiling and gap rule; `raiseCaps` up to the asset's cap ceiling with **no rate limit** (the +25% per 7 days limit is removed). Cap ceilings are the only on-chain limit on `K_LOOSEN` cap growth; they are set per asset by MS_OPS at listing, MS_OPS can raise them instantly, and they must be conservative. An off-chain alert on every cap raise must exist before `K_LOOSEN` is enabled. `K_LOOSEN` is held by MS_OPS in phase 1 and moves to a KMS key through the timelock in phase 2; no on-chain switch. Escrow borrow caps stay at zero.
* `list`: LTV <= 50% of class ceiling, supply cap <= 25% of cap ceiling. `promote`: all-or-nothing across hubs at launch limits. `emergencyLowerLiquidationLTV`: MS_OPS, <= 15 pts, ramp >= 12h.
* `demote` (`K_TIGHTEN`): borrow LTV to 0 at once in hubs the asset is leaving; liquidation LTV ramps to 0 over at least (delta / 5 pts) x 24h. The same rules apply in the band hub the asset stays in: borrow LTV drops to the new class ceiling at once and liquidation LTV ramps down over at least (cut / 5 pts) x 24h, never under 72h. Own rate limit (proposed <= 3 per rolling 7 days).

## §7 Scripts

* `Deploy.s.sol`: deploys and wires the full stack; per hub sets `CFG_DONT_SOCIALIZE_DEBT`, IRM, interest fee, max liquidation discount and **fee receiver** (also where origination fees go; must be non-zero); deploys the wrapper factory (dividend sweep recipient = the reserve Safe) and both Earn vaults; grants `K_LOOSEN` to the MS_OPS Safe for phase 1.
* `BuildListingBatch.s.sol`: reads `config/assets.json`; each asset has an issuer mechanism (`multiplier`, `balance-changing`, `distributing`). Two stages. Stage 1 (deployer key, not the Safe): deploy the wrapper (`balance-changing` and `distributing` assets) -> create the escrow (seed deposit, hook config, hand governance to the Governor). Stage 2 (MS_OPS Safe batch): list token -> `addWrapper` (wrapped assets only) -> routes and resolved vault -> steward `list`. Outputs Safe Transaction Builder JSON for stage 2. Flagged for review (Q1).
* `ConfigCheck.s.sol`: diffs on-chain state against the JSON before and after each batch.
* Runbook (manual): the MS_OPS unpause after a corporate action happens only once both the token's balance or multiplier and the price reflect the action.
* Reserve Safe Roles module is configuration only: documented and checked by a fork test.

Scripts are verified by simulation, anvil or a fork only. Running them against a live network is human-only (see `AGENTS.md`).

## §8 Tests

* **Unit, fuzz and invariant** tests per contract.
* **End-to-end on local EVK:** batched borrow + `forward` succeeds; direct and `max` borrows and flash loans revert; status check passes on liquidate/repay/deposit; collateral seizable while deposits are paused; liquidation reverts while Closed; withdraw and repay never blocked; reserve repays bad debt.
* **Wrapper:** pro-rata positive and negative rebases; no first-depositor inflation; share count unaffected by rebases; pricing through escrow -> wrapper -> token; `sweep` never moves the underlying token and sends only to the factory's recipient.
* **Arbitrum fork:** canonical Euler versions; Earn accepts hooked hubs; real xStocks and rTokens (where deployed): a split and a dividend rebase through the full stack.
* **Issuer freeze:** issuer freezes the escrow or wrapper address; withdrawals fail (assert the on-chain symptom only; monitoring is deferred, Q11).
* **Scale:** 300-500 collaterals in one hub (`setLTV`, `LTVList()`, lenses, account checks); pushes of 100/250/500 assets in both formats; 500-asset `confirmBatch`; steward batch calls.

## §9 Order of work

Repo setup -> oracle and adapter -> status-check hook prototype on EVK -> fee router and hub hook -> wrapper and factory -> escrow hook -> router governor -> steward -> scripts -> integration, fork and scale tests -> update `CONTRACT_SPEC.md`, README and SECURITY, static analysis and audit prep.

## Defaults (unless changed in OPEN_QUESTIONS)

`n = 3`, `minPendingSpacing` = 10 min; no cumulative daily price cap; `demote` limit <= 3 per 7 days; no extra grace period after Arbitrum sequencer downtime.

## Known gaps (noted, not fixed)

* `CONTRACT_SPEC.md` line 3 refers to a "Problems doc" that is not in the repo.
* `ARCHITECTURE.md §Listing` says "approved Ondo token list", but §Issuers covers several issuers (Ondo, xStocks, Reality, Dinari).
* `docs/Poppie-Arbitrum-Hub-Architecture-Governance-Plan.pdf` is not kept in the repo; `ARCHITECTURE.md` is its newer Markdown conversion and supersedes it (see `docs/README.md`).
