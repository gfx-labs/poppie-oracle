# Contracts: evaluation findings and test evidence

*Evaluation of the audited v1 `PoppieEulerOracle` and `PoppieEulerAdapter` and stock Euler for Arbitrum. Branch `v2`; `src/` is identical to tag `v1-bsc` (`git diff v1-bsc HEAD -- src` is empty). No v1 source was modified. Live networks were only read or forked locally; nothing was broadcast. Issuer findings are in `docs/issuerResearch/` (xStocks, Robinhood, Reality, Dinari-Ondo); keeper findings in `docs/evaluation/Keeper.md`.*

**Result:** no finding requires modifying `PoppieEulerOracle` or `PoppieEulerAdapter`.

**IDs:** A = the v1 oracle and adapter; B = stock Euler components (B1 emergency governor roles, B2 cap steward, B3 disabling ops by hook, B4 no token recovery and `skim`, B5 supply-cap freeze, B6 what a stale price freezes, B7 router pricing path, B8 router governor power, B9 scale of one hub, B10 Arbitrum fee configuration); C = issuer mechanics (table below); "C-extra" = the OZ `ERC4626` fallback wrapper. The original questions are in `docs/legacy/Design.md` §3. Decision IDs (D1–D19) are defined in `docs/zeroContracts/Design.md` and `docs/peripheralContracts/Design.md`.

Build health: the default (audited) profile is unchanged. `forge build` passes (adapter 3,737 B runtime, oracle 7,385 B), `forge test` passes 121/121, and slither reports only `block.timestamp` comparisons.

## Tests

The evaluation tests live in `eval/`, outside `test/`, so the default `forge test` never compiles them. Two profiles were added to `foundry.toml`; the default profile is untouched.

| Command | Compiles with | Tests |
|---|---|---|
| `FOUNDRY_PROFILE=eval-oracle forge test` | Audited settings (solc 0.8.24, shanghai) | `eval/oracle/` (23) |
| `FOUNDRY_PROFILE=eval forge test` | cancun, needed by OZ 5.6.1 `ERC4626`. `src/` is recompiled, so this is not the audited bytecode; behaviour is identical | all of `eval/` (63, plus 23 fork tests) |

The `eval` profile uses the stock `EulerRouter` from `lib/euler-price-oracle`, whose nested EVC and solady submodules must be initialised once:

```
git -C lib/euler-price-oracle submodule update --init --depth 1 lib/ethereum-vault-connector lib/solady
```

All 63 non-fork tests pass; the fuzz tests also pass at 10,000 runs.

Three fork suites run locally (nothing is broadcast) and are skipped unless their RPC URL is set:

```
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/XStocks*'
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/Robinhood*'
ARBITRUM_RPC_URL=<archive-capable RPC> FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/Reality*'
```

`XStocksArbFork` tests the real AAPLx token and V2 wrapper on Arbitrum: all 5 pass (2026-11-02). `RobinhoodChainFork` tests the real AAPL Stock Token on Robinhood Chain (chain 4663): all 9 pass (2026-11-04). `RealityArbFork` tests real rTokens on Arbitrum: all 9 pass (2026-11-05, Alchemy RPC). The suite is pinned to block 521,342,402 (before Reality executed the rSOXX split), so it needs an archive RPC.

| File | Covers |
|---|---|
| `eval/oracle/OracleEval.t.sol` | A1–A7, A9–A11; split and reverse-split pushes; fuzzed breaker boundary; 100/250/500-asset gas |
| `eval/wrapper/WrapperEval.t.sol` | C-extra: OZ `ERC4626` over a rebasing token (pro-rata splits, reverse splits and reinvested dividends; 1-wei transfer drift; donation attack with a seed; stuck stablecoins; adapter pricing the share through a split) |
| `eval/euler/RouterEval.t.sol` | B7 and B8 with the stock `EulerRouter` and the v1 adapter: the two pricing paths, route precedence, stale and paused reverts through the router, governor overwrite power, fuzzed path equivalence |
| `eval/dividends/DividendCaptureEval.t.sol` | DIV-1 prototype: pushed and claim-based dividends, hostile and re-entering distributors, end-to-end through router and adapter |
| `eval/mocks/MockXStock.sol` | Model of an xStocks EVM token: share units × scheduled multiplier, same `multiplierUpdates` getters Euler's own xStocks adapter reads. Rounding is modelled, not copied from Backed |
| `eval/fork/XStocksArbFork.t.sol` | XS-1 to XS-4 on the real AAPLx contracts: wrapper facts, 1:1 backing through deposit and redeem, a Backed-scheduled 2:1 split through `EulerRouter` and the v1 adapter, wrapper and token pauses |
| `eval/prototypes/DividendCaptureWrapper.sol` | **Test-only, unaudited** prototype of the DIV-1 contract |
| `eval/mocks/MockRobinhoodStockToken.sol` | Model of a Robinhood Stock Token: ERC-8056 static balances, `uiMultiplier`/`newUIMultiplier`/`effectiveAt`, both `updateMultiplier` overloads, `oraclePaused`, token pause, blocklist, `adminBurn`. No access control |
| `eval/robinhood/RobinhoodEval.t.sol` | RH-1 to RH-7 on the mock: direct route through forward splits, reverse splits and reinvested dividends (fuzzed over ratios); wrong pushes against the breaker; rogue multiplier; burn from an OZ escrow and from a model of EVK's internal cash accounting; pause and blocklist vs share seizure; `oraclePaused` keeper rule |
| `eval/mocks/MockRealityToken.sol` | Model of a Reality rToken in both balance models: the legacy rebase index, and the current ERC-8056 multiplier applied at once, plus the 2026-10-17 migration. Pause, freeze, delist. No access control |
| `eval/reality/RealityEval.t.sol` | RE-1, RE-3, RE-4, RE-6, RE-9 on the mock: a current-model split; a duplicated reverse split against the breaker; a cash dividend dip; legacy rebases and the migration against an OZ escrow and EVK-style cash accounting; freeze and pause vs share seizure |
| `eval/fork/RealityArbFork.t.sol` | RE-1, RE-2, RE-6, RE-7 on real rTokens: roles, Safes and interfaces; a registry-backed rSOXX 3:1 split through `EulerRouter` and the v1 adapter; registry guards and early execution; registry replacement; beacon upgrade; pause, freeze, `emergencyWithdraw`, delist |
| `eval/fork/RobinhoodChainFork.t.sol` | RH-1, RH-2, RH-4, RH-5, RH-7, RH-8, RH-10 on the real AAPL token: interfaces, registry and role holders, Chainlink feed, a scheduled 2:1 split through `EulerRouter` and the v1 adapter, unbounded updater, burn from an escrow, token and registry pause, blocklist, advisory oracle pause |

The EVK escrow vault is stood in for by an OZ `ERC4626` in the router tests; `EulerRouter` only calls `asset()` and `convertToAssets()` on a resolved vault. EVK-specific behaviour (B3–B6, account checks, liquidation) needs an EVK harness (POP-33).

## Blockers and new on-chain logic

| ID | Status | Finding | Minimum change |
|---|---|---|---|
| DIV-1 | **Deferred** (not needed at launch: only reinvesting issuers are listed). Blocker if cash or claim-based dividends are captured later (POP-72) | Stablecoin dividends pushed to the holder, or claimable by the holder, cannot be recovered from an EVK escrow or an unmodified OZ `ERC4626` (`test_stablecoinDividendIsStuck`). EVK has no token-recovery or arbitrary-call path (from EVK design and `scale:docs/ARCHITECTURE.md:89-97`; not yet tested on local EVK, see B4). | New **dividend-capture wrapper**: OZ `ERC4626` (`decimalsOffset = 0`, seed deposit) plus `sweep(token)` for any token except the underlying, sending to an immutable reserve, and `claim(target, data)` limited to an operator and allowlisted distributors (never the underlying or the wrapper), with a post-call check that the underlying balance did not drop and re-entry blocked. A test-only prototype (`eval/prototypes/DividendCaptureWrapper.sol`, about 60 lines of logic) passes all 8 tests in `eval/dividends/`, including hostile and re-entering distributors, and prices unchanged through the v1 adapter and `EulerRouter`. Production version needs its own spec and audit. Only needed for issuers with cash or claim-based dividends. |
| PATH-2 | Issue, configuration rule | With the stock `EulerRouter`, resolving the wrapper to the rebasing token and pricing the token makes collateral value jump with the multiplier on-chain, while the push oracle still holds the pre-split price: 2× overvalued at a 2:1 split until the next push, 3× at 3:1, and the 3:1 correction (−66.7%) cannot pass a 5000 bps breaker (`test_B7_path2_resolvingToRebasingToken_overvaluesAtActivation`). Euler's own xStocks adapter avoids this by reverting around activation (`lib/euler-price-oracle/src/adapter/chainlink/ChainlinkInfrequentXStocksOracle.sol:18-22`); the v1 oracle has no cheap equivalent, since pause wipes price state. Pricing the wrapper share directly is continuous through activation (`test_B7_path1_wrapperShareIsBase_splitIsContinuous`), and a direct route takes precedence over a resolved vault (`test_B7_directConfigTakesPrecedenceOverResolvedVault`). | Config-check script: every rebasing asset has a direct `wrapper/USD → adapter` route and no `govSetResolvedVault(wrapper)`. No contract change. |
| KEEP-1 | Issue, workaround | Single `keeper` address (`PoppieEulerOracle.sol:24,35-38`). Losing the key stops pricing until the admin calls `setKeeper` (`:226-230`). | No contract needed at launch: several keeper processes share one KMS key, and the Oracle Safe calls `setKeeper` for failover (instant). Options: a keeper Safe with Zodiac Roles (D14, zero-contract design; needs keeper changes, KEEP-21) or the P4 keeper forwarder (peripheral design). |
| PAUSE-1 | Issue, off-chain | Issuers pause assets on schedule (Ondo: 20 min, 00:52–01:12 UTC weekdays, `ASSET_PAUSED`, daily share-multiplier update). v1 cannot pause and resume on a schedule: `pauseAssets` erases the price (`PoppieEulerOracle.sol:135-138`), and resuming needs `adminSetPrice` (`:95-97`). EVK hooks can: a hook target is called with the original calldata plus caller and may revert (`Base.sol` `invokeHookTarget`); ops are bit flags (`Constants.sol`: `OP_DEPOSIT`…`OP_SKIM`). Liquidation seizes via the escrow's `transfer` (`OP_TRANSFER`), so leaving that op unhooked keeps liquidations open | Zero-contract design (D8): app and SDK block deposit and withdraw during published windows; the keeper skips any name whose token or wrapper is paused on-chain, and never pauses the oracle. The BSC keeper instead calls `pauseAssets` on Ondo's `ASSET_PAUSED`, which wipes the price; v2 does not carry that over. Peripheral design: the P2 escrow guard enforces windows on-chain. No v1 change |

## Per-issuer mechanics (C)

| Issuer | Balance model | Splits | Dividends | Wrapper | Arbitrum | Status |
|---|---|---|---|---|---|---|
| **xStocks** | EVM `balanceOf()` rebases when the multiplier changes; constant `sharesOf()`; `getCurrentMultiplier()` | Multiplier change; activation time varies (00:30, 01:30, 13:45, 14:00, 23:55 UTC seen; XS-6, KEEP-19); read `newMultiplierActivationTime` | Reinvested via the multiplier | Issuer ERC-4626. **V2 wrapper** only: the legacy wrapper is donation-manipulable and the issuer says not to use it as collateral | ~1,490 names deployed (KEEP-4) | Listable with caps sized to exit depth; hold the V2 wrapper |
| **Dinari** | Token balance-per-share rebases on splits | Forward and reverse; trading halts; reverse splits may pay USD+ for fractions | Raw dShare: USD+ paid only to wallets registered to a KYC'd entity. Wrapped dShare: reinvested as dShares | Issuer wrapped dShare | 251 names deployed (DN-1) | **Blocked**: the wrapper's `recover` lets the issuer remove backing (DN-2) |
| **Ondo GM** | Static balances; total-return tracker (dividends reinvested, net of withholding) | Reflected in the per-token price | Reinvested | Not needed | **Not deployed**: docs say Ethereum, BNB Chain, Solana (plus HyperEVM and Robinhood Chain via bridge); no code at the BSC addresses (ON-1) | Unavailable |
| **Robinhood** | Static raw balances (ERC-8056); `uiMultiplier()` scales shares per token; not rebasing | Multiplier change, forward and reverse; CRWD took effect at the US open | Reinvested via the multiplier | **Not needed**: the token is the oracle base | Robinhood Chain (4663) only; Arbitrum expected | Fits as is; issuer burn and multiplier risk (RH-4, RH-5) |
| **Reality** | Static raw balances (ERC-8056) since 2026-10-17; **rebased (`rebaseIndex`) before** | Registry action, executed by the Safe; the multiplier changes at once (no schedule); forward and reverse | **Paid separately to the depositor** (cash in USDT0, stock in rTokens) via Merkl attribution; withheld while the protocol is unsupported | **Not needed**: the token is the oracle base | Arbitrum One (native) and Morph | Fits technically; listing blocked by liquidity (RE-10) and issuer record (RE-3, RE-4); dividends need Merkl support (RE-9) |
| **Others** | Not researched | | | | | Needs external info (POP-72) |

Sources (Reality: press only; its docs are geo-blocked): https://www.bitget.com/blog/articles/bitget-reality-tokenized-rwa-platform, https://web3.bitget.com/en/blog/articles/reality-rtokens, https://docs.xstocks.fi/developers/multipliers.md, https://docs.xstocks.fi/developers/wrapped-xstocks.md, https://docs.dinari.com/docs/dividend-payments.md, https://docs.dinari.com/docs/stock-split-handling.md, https://docs.ondo.finance/ondo-global-markets/overview, https://docs.robinhood.com/chain/stock-tokens/, https://docs.robinhood.com/chain/building-with-stock-tokens/, https://docs.robinhood.com/chain/oracles-and-price-feeds/, https://docs.robinhood.com/chain/stock-token-apis/, https://eips.ethereum.org/EIPS/eip-8056

## Dividend handling options

| Delivery | Example | Handling | Protocol revenue |
|---|---|---|---|
| Reinvested (multiplier or total return) | xStocks, Robinhood, Ondo, Dinari wrapped | None; value goes to depositors through the share price | No |
| Stablecoins pushed to holder | Dinari raw dShare (if the contract is KYC-registered) | Dividend-capture wrapper, `sweep` to the reserve | Yes |
| Must be claimed by holder | Any issuer with a claim distributor | Dividend-capture wrapper, `claim` then `sweep` | Yes |
| Attributed to the depositor through supported protocols (Merkl snapshot); withheld for unsupported ones | Reality (USDT0 and stock rTokens) | None in the contracts. Withheld by Reality unless Merkl supports Poppie's escrows (POP-60) | No (belongs to depositors) |
| Pushed to a plain escrow or OZ wrapper | — | Lost (stuck) | No; do not list this way |

Using captured dividends in borrow parameters: EVK has no per-collateral rate, so a dividend cannot lower a specific borrower's rate on-chain without more contracts. Off-chain uses:
- set LTV buffers above the largest expected dividend, including specials, because the wrapper share drops by the dividend on the ex-date;
- fund the loss reserve;
- add to interest-fee and origination-fee revenue (D2, D16).

Depositors forgo cash dividends while deposited; this needs disclosure (legal and tax review: POP-55).

## Corporate-action pricing risk

- The breaker check is a strict `>` against the old price (`PoppieEulerOracle.sol:104`), and the cumulative check uses the same bps maths (`:297`). A −50% push passes a 5000 bps threshold, the single-stock default in `script/ConfigureDev.s.sol:27`.
- Thresholds are capped at 10000 bps (`:162-163`), measured against the old price (`:306-311`). Moves above +100% (reverse split on a per-token price, squeezes, leveraged ETFs) need `adminSetPrice`.
- Tests: `test_split2to1_mispush_passes_afterRotation`, `test_split2to1_mispush_passes_withinWindow`, `test_split3to1_needsAdmin`, `test_reverseSplit1to3_needsAdminEvenAtMaxThresholds`.
- Pricing the wrapper share as equity price × equity per share keeps the on-chain value continuous when the multiplier activates (`test_adapterPricesWrapperShareThroughSplit`, `test_B7_path1_wrapperShareIsBase_splitIsContinuous`). It only stays right if the keeper uses the multiplier in effect at the push block: xStocks activation times vary and are not aligned with when split-adjusted prices start trading (KEEP-10). The keeper polls `newMultiplierActivationTime` and `newMultiplier`, not `multiplierUpdates`, which 87% of Arbitrum tokens lack (KEEP-5).
- Robinhood (static balances, token as base) gives the same continuity without a wrapper. A keeper that ignores the multiplier pushes −75% at a 4:1 split (rejected by a 5000 bps breaker), −50% at 2:1 (passes 5000, rejected at 4000), and +900% at a 1:10 reverse split, which no threshold allows (`test_RH_mispush4to1_rejectedByBreaker`, `test_RH_mispush2to1_passes5000_rejectedBelow`, `test_RH_mispushReverseSplit_neverPasses`). The correct push at any ratio is 0%, so Robinhood reverse splits need no `adminSetPrice`.
- A keeper that follows an unexplained multiplier change (RH-6) moves collateral value with it, within the breaker: a ×1.4 change passes a 5000 bps breaker (`test_RH_rogueMultiplierDoesNotMoveValue`). The keeper must only apply multiplier changes that match a published corporate action.
- Wrapping an issuer token in an unmodified OZ `ERC4626` is workable: splits, reverse splits and reinvested dividends are shared pro rata and everyone can exit in full (`test_rebasesAreProRata`); with a 1e18 seed a donation attack costs the attacker the donation and the victim loses only rounding (`test_inflationAttackWithSeed`); and if the issuer token rounds transfers down, each deposit leaks a few wei from existing holders but never causes insolvency (`test_transferDriftIsBounded`, under a modelled rounding rule).

## A. v1 oracle and adapter

| ID | Status | Evidence | Impact at 500 assets | Workaround |
|---|---|---|---|---|
| A1 | Issue, workaround | `PoppieEulerOracle.sol:86-108`; `test_A1_oneBadEntryRevertsWholeBatch`, `test_A1_unconfiguredAssetRevertsBatch` | Any bad entry reverts a whole chunk | The keeper simulates the breaker and cumulative cap off-chain, drops failing assets, and retries a reverted batch once without the asset named in the revert. The BSC keeper's retry does not run for guard reverts (KEEP-22); v2 fixes it, models anchor rotation in the off-chain check and adds chunking |
| A2 | Issue, workaround | Per-asset thresholds `:180-190`, range 0–10000 bps, cumulative cap must be non-zero (`:159,184`), admin-only. Pass iff `floor(|Δ|·1e4/old) ≤ threshold` (`testFuzz_A2_breakerBoundary`, 10k runs); `test_A2_thresholdBounds` | Monday open or earnings gaps beyond thresholds need admin calls | Size thresholds per class (below 5000 for split-prone names); batch admin calls via Safe MultiSend |
| A3 | Not an issue | Anchor rotates to the new price once the window expires (`:289-294`); `test_A3_freezeThenResumeWithoutAdmin`. A gap beyond the breaker still needs admin (`test_A3_gapBeyondBreakerNeedsAdmin`); inside a window the cap binds cumulatively (`test_A3_cumulativeCapBindsWithinWindow`) | Stop pushing → stale → resume works without admin, within the breaker | Supports the closed-market rule (D1) |
| A4 | Issue, workaround | Pause zeroes price state (`:135-138`); recovery needs `adminSetPrice` (`:193`) plus a keeper push; `pauseAssets` reverts on an already-paused entry (`:133`); `test_A4_pauseWipesStateAndNeedsAdminPlusKeeper`, `test_A4_pauseBatchRevertsIfAnyAlreadyPaused` | Mass recovery = hundreds of admin calls | Reserve pause for emergencies; filter already-paused assets; batch via MultiSend |
| A5 | Not an issue | Per-asset override, else the global value; both zero disables; stale when `age > maxAge` (`:61-65`); `test_A5_staleBoundaryAndOverride` | — | Per-asset overrides for halt-prone names |
| A6 | Issue, workaround | One admin with two-step transfer (`:233-250`); one keeper (`:24`); admin can be a contract; admin holds instant price power (`test_A6_adminCanBeAContract_singleKeeper`) | Keeper is a liveness single point of failure | See KEEP-1; keeper Safe with Zodiac Roles (D14) or P4; oracle admin options D13 |
| A7 | Not an issue | Mapping storage, 2 slots per asset (`IPoppieEulerOracle.sol:7-34`); no loop over all assets; read gas independent of asset count (`test_A7_readIsConstant`). Measured (`test_A7_gas100/250/500`): push 7.1k gas per asset, configure 29.7k, seed via `adminSetPrice` 23.6k | 500 assets: push 3.55M, configure 14.8M, seed 11.8M gas, each under a 32M limit (Arbitrum's limit: POP-12) | Chunk pushes anyway for simulation and partial failure; split configure and seed batches |
| A8 | Not an issue (code); issue (scripts) | No `block.number`, `chainid` or hard-coded addresses in `src/`; solc 0.8.24, `evm_version = shanghai` (`foundry.toml:5-8`). Scripts hard-code BSC addresses (`script/ConfigureDev.s.sol:23-24,44+`) | — | New Arbitrum scripts; verify deployed bytecode against the shanghai build |
| A9 | Not an issue | Bid = ask (`PoppieEulerAdapter.sol:228-233`); quote limited to `unitOfAccount` (`:223,229`); oracle reverts pass through (`:245`); any configured address can be a base (`:130-178`); `test_A9_bidEqualsAsk_quoteOnlyUsd_revertsPropagate` | Wrapper-share pricing works | — |
| A10 | Not an issue | Decimals ≤ 18 (`:138`), cross-checked against `decimals()` (`:173-177`); `test_A10_decimalsBound`. OZ `ERC4626` with `decimalsOffset = 0` matches the underlying (`test_decimalsMatchUnderlying`). Minor: a base with no code reverts `registerBase` because the failed return-data decode happens outside the `try` (`test_A10_codelessBaseCannotBeRegistered`) | — | Require `decimalsOffset = 0`; register only deployed contracts |
| A11 | Not an issue | No singleton or global assumptions; adapter `master` is immutable per instance (`PoppieEulerAdapter.sol:40,107`); `test_A11_independentInstances` | Per-issuer or per-band instances possible | Input to D7 |
| A12 | Not an issue | Audit by Chain Defenders (June 2026); the deployed `v1-bsc` code includes the post-audit fixes in `56b107a`, assumed fix-reviewed. No finding depends on BSC, and the report does not discuss issuer count, asset count, rebasing or dividends; its only chain-specific detail is "USDT borrowable". L-02 (no direct unpause) is kept by design (`IPoppieEulerOracle.sol:144-151`). L-03 (deployer key from env) applies to any new Arbitrum scripts | — | Use a keystore or KMS signer in new scripts |

Build note: `lib/openzeppelin-contracts` is v5.6.1, whose `ERC4626` does not compile under `shanghai` (`mcopy` not found). Compile new wrapper or forwarder contracts in a separate profile (cancun, or OZ v5.1.0 as pinned on `scale`). Keep the oracle and adapter at the audited shanghai settings.

## B. Stock Euler components

**B7 (router part) and B8: verified** with the stock `EulerRouter` from `lib/euler-price-oracle` (`eval/euler/RouterEval.t.sol`).

| ID | Status | Evidence |
|---|---|---|
| B7 | Not an issue for the router path; EVK account checks and liquidation still pending (POP-33) | escrow → wrapper (resolved) → wrapper share via the v1 adapter prices correctly, bid = ask, and stale or paused prices revert through the router with the oracle's own error (`test_B7_path1_wrapperShareIsBase_splitIsContinuous`, `test_B7_staleAndPausedPropagateThroughRouter`). See PATH-2 for the path to avoid |
| B8 | Issue, decided (D5) | The router governor is one address with full power: it can overwrite a live route with any oracle or delete it (`test_B8_governorCanOverwriteAndDeleteLiveRoutes`; `EulerRouter.sol` `govSetConfig`). Zero-contract design: `MS_OPS` lists instantly, or every router change waits for a timelock (D5, D12). Limiting it to unset routes needs a governor contract in front: P5 in the peripheral design |

**Earn (read from source, `b2fd6e6`):** an Earn vault can raise a strategy's cap only if `EulerEarnFactory.isStrategyAllowed` accepts it: verified by the factory's perspective contract, which Euler controls, or itself an Earn vault. Whether Poppie's hubs pass the Arbitrum perspective is not yet checked (POP-12); if not, lenders deposit into hubs directly. The curator can also allocate (`onlyAllocatorRole` accepts the curator).

**B1–B6, B9, B10: not verified.** This branch has no EVK, EVC (beyond the utility nested in `euler-price-oracle`), evk-periphery or Earn sources. Tracked in POP-33 (B1–B7) and POP-12 (B9, B10).
