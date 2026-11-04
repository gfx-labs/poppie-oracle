# Poppie on Arbitrum with the v1 contracts: evaluation findings

*Evaluation of `docs/Design.md` against the audited v1 code. Branch `v2`; `src/` is identical to tag `v1-bsc` (`git diff v1-bsc HEAD -- src` is empty). No v1 source was modified. Nothing was run against a live network.*

## Summary

- **Splits and rebases can be handled without modifying the v1 contracts.** The v1 `PoppieEulerOracle` and `PoppieEulerAdapter` work as they are, provided rebasing tokens are held through a non-rebasing ERC-4626 wrapper. Issuer wrappers exist for xStocks and Dinari. The wrapper share becomes the oracle base.
- **Dividends the protocol must claim, or that arrive as stablecoins, need one small new contract.** Neither an EVK escrow vault nor an unmodified OpenZeppelin `ERC4626` can recover tokens sent to it. A minimal dividend-capture wrapper (about 100 lines) lets the protocol be the holder of record, claim and sweep dividends, and count them as revenue.
- **The main operational risk is a wrong price push at a split.** The oracle cannot tell a split from a market move. A wrong 2-for-1 push passes the 5000 bps breaker used in the dev scripts, and moves above +100% need `adminSetPrice`. This is handled off-chain by the corporate-action engine.
- **The wrapper share must be the oracle base; never route through to the rebasing token.** Through the stock EulerRouter, pricing the wrapper share directly keeps collateral value continuous when a multiplier activates. Resolving the wrapper to the rebasing token instead (the pattern xStocks' docs describe: `convertToAssets` × token price) overvalues collateral 2× at a 2:1 split until the keeper pushes, and a 3:1 split cannot be fixed by the keeper at all (PATH-2).
- **xStocks contracts fit; the market doesn't exist yet (XS-1 to XS-6).** Fork tests on the real AAPLx token and V2 wrapper confirm the pricing path, including a split. But over 99% of Arbitrum supply of the major names is Backed inventory, the V2 wrappers are unused and there are no Uniswap v3 USDC pools, so liquidators have no exit today. On-chain, the only exit is Backed's own inventory through its allowlisted `AtomicSwap` RFQ, which CoW solvers also use; sales so far are small and never at weekends (XS-7). The multiplier key has no on-chain bound on size or notice (XS-9). Corporate-action payouts to wrapper holders are unconfirmed (XS-8).
- **Scheduled issuer pauses need one small new contract, not a v1 change (PAUSE-1).** An EVK hook on each escrow can freeze deposits and withdrawals during known windows while leaving liquidations open.
- **Listability:** Ondo's docs do not list Arbitrum as a supported chain. Most of the Arbitrum set may need to come from xStocks and Dinari.

Build health: the default (audited) profile is unchanged. `forge build` passes (adapter 3,737 B runtime, oracle 7,385 B), `forge test` passes 121/121, and slither reports only `block.timestamp` comparisons.

### Evidence from tests

The evaluation tests live in `eval/`, outside `test/`, so the default `forge test` never compiles them. Two profiles were added to `foundry.toml`; the default profile is untouched.

| Command | Compiles with | Tests |
|---|---|---|
| `FOUNDRY_PROFILE=eval-oracle forge test` | Audited settings (solc 0.8.24, shanghai) | `eval/oracle/` (23) |
| `FOUNDRY_PROFILE=eval forge test` | cancun, needed by OZ 5.6.1 `ERC4626`. `src/` is recompiled, so this is not the audited bytecode; behaviour is identical | all of `eval/` (43) |

The `eval` profile uses the stock `EulerRouter` from `lib/euler-price-oracle`, whose nested EVC and solady submodules must be initialised once:

```
git -C lib/euler-price-oracle submodule update --init --depth 1 lib/ethereum-vault-connector lib/solady
```

All 43 tests pass; the two fuzz tests also pass at 10,000 runs.

A sixth suite, `eval/fork/XStocksArbFork.t.sol`, forks Arbitrum locally (nothing is broadcast) and tests the real AAPLx token and V2 wrapper. It is skipped unless `ARBITRUM_RPC_URL` is set:

```
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc FOUNDRY_PROFILE=eval forge test --match-path 'eval/fork/*'
```

All 5 fork tests pass (2026-11-02).

| File | Covers |
|---|---|
| `eval/oracle/OracleEval.t.sol` | A1–A7, A9–A11; split and reverse-split pushes; fuzzed breaker boundary; 100/250/500-asset gas |
| `eval/wrapper/WrapperEval.t.sol` | C-extra: OZ `ERC4626` over a rebasing token (pro-rata splits, reverse splits and reinvested dividends; 1-wei transfer drift; donation attack with a seed; stuck stablecoins; adapter pricing the share through a split) |
| `eval/euler/RouterEval.t.sol` | B7 and B8 with the stock `EulerRouter` and the v1 adapter: the two pricing paths, route precedence, stale and paused reverts through the router, governor overwrite power, fuzzed path equivalence |
| `eval/dividends/DividendCaptureEval.t.sol` | DIV-1 prototype: pushed and claim-based dividends, hostile and re-entering distributors, end-to-end through router and adapter |
| `eval/mocks/MockXStock.sol` | Model of an xStocks EVM token: share units × scheduled multiplier, same `multiplierUpdates` getters Euler's own xStocks adapter reads. Rounding is modelled, not copied from Backed |
| `eval/fork/XStocksArbFork.t.sol` | XS-1 to XS-4 on the real AAPLx contracts: wrapper facts, 1:1 backing through deposit and redeem, a Backed-scheduled 2:1 split through `EulerRouter` and the v1 adapter, wrapper and token pauses |
| `eval/prototypes/DividendCaptureWrapper.sol` | **Test-only, unaudited** prototype of the DIV-1 contract |

The EVK escrow vault is stood in for by an OZ `ERC4626` in the router tests; `EulerRouter` only calls `asset()` and `convertToAssets()` on a resolved vault. EVK-specific behaviour (B3–B6, account checks, liquidation) still needs an EVK harness.

## xStocks on Arbitrum (read on-chain 2026-11-02)

Read-only `cast` calls against public Arbitrum RPCs, plus the fork suite. Addresses are in the plan's "xStocks on Arbitrum" section.

| ID | Status | Finding | Evidence |
| --- | --- | --- | --- |
| XS-1 | Not an issue | The V2 wrapper (`WrappedBackedTokenImplementation` v1.0.0, implementation `0x76C6…5583`) maps one wrapper share to one token share unit: `convertToAssets(1e18) == getCurrentMultiplier()` (AAPLx `1003269012539818700`, SPYx `1007474126658766000`). `totalAssets` is supply × multiplier, so donations cannot move it. Deposit mints exactly the share units received; redeem keeps backing ≥ supply | `test_fork_wrapperFacts`, `test_fork_depositRedeemKeepsOneToOneBacking`; ProxyAdmin `getProxyImplementation` |
| XS-2 | Not an issue | A Backed-scheduled 2:1 split leaves wrapper shares unchanged, doubles `convertToAssets`, does not move the router value at activation, and the keeper's per-share push is a 0% move | `test_fork_splitThroughRouterIsContinuous` |
| XS-3 | Issue, workaround | Wrapper pause stops all wrapper share transfers, so escrow deposit and withdraw revert. Token pause only blocks unwrapping. The test used a mock escrow: in EVK, liquidation seizes escrow shares via `transfer` (`Liquidation.sol` `enforceCollateralTransfer`), which does not move the wrapper, so seizure likely still succeeds (see PAUSE-1) | `test_fork_wrapperPauseFreezesEscrowMovement`, `test_fork_tokenPauseBlocksUnwrapOnly` |
| XS-4 | Issue, needs Backed | `multiplierUpdater` (and `burner`) is a single EOA, `0x5F7A…a2aD`, which can set any multiplier. Owner of token, wrapper and both ProxyAdmins is a 2-of-3 Safe with no timelock; pauser is a 3-of-5 Safe that includes the same EOA. Confirmed role: `multiplierUpdater()` returns it, `NewMultiplierUpdater` emitted at deployment. Plain EOA, 19,622 Arbitrum and 38,073 Ethereum transactions (automated hot key). Backed (2026-11-03): values come from "verified data sources" | `cast call`, `cast logs`; Backed reply |
| XS-5 | **Likely blocker for listing** | Over 99% of Arbitrum supply of AAPLx, SPYx, TSLAx, NVDAx, MSFTx (and ~98–99% of QQQx, GOOGLx) sits in the Backed EOA; V2 wrappers hold 0 (NVDAx 0.17); no Uniswap v3 USDC pools for AAPLx or SPYx; 31 AAPLx transfers moved 0.7 tokens in 80 hours. Ethereum looks similar for AAPLx (72,457 of 74,145 in the same EOA). No DEX exit. All observed liquidity is Backed's inventory through `AtomicSwap` (see XS-7) | `cast call`, `cast logs` |
| XS-6 | Not an issue now | `feePerPeriod = 0`, `periodLength = 604800`: no management-fee decay today. Activation times vary (SPYx: 2026-10-30 23:55 and 2026-10-31 13:45 UTC; AAPLx: 2026-08-08 00:30 UTC), and the Arbitrum multiplier matches Backed's API | `multiplierUpdates`, xStocks API |
| XS-7 | **Blocker until exit is confirmed** | Backed's `AtomicSwap` `0x6F86…8852` (RFQ: Backed-signed quotes, allowlisted callers, counterparty and owner EOA `0x5F7A…`, upgradeable, pausable) filled 296 swaps in 27 names, 2026-05-28 to 2026-11-03. Taker sells (the liquidation direction): 115 swaps, $142k total, largest $38k, median $28. Taker buys: $1.03M, largest $434k. No weekend fills; weekday fills in all sessions. 58 of 59 CoW trades in xStocks were solvers calling `AtomicSwap`. Wrappers never traded. Via CoW, liquidation is asynchronous (no flash loans); an atomic route needs Backed to allowlist Poppie's liquidator | `cast logs` on `AtomicSwap` and 16 token and wrapper contracts; settle calldata decode |
| XS-8 | Issue, needs Backed | Mergers, spin-offs, delistings and migrations are handled case by case ("users are made whole"), with notice depending on when Backed learns. Unconfirmed whether cash or second-token payouts reach V2 wrapper holders | Backed reply |
| XS-9 | Issue, needs Backed | No on-chain bound on multiplier updates: simulated calls from the updater succeed for ×1000, ×0.001, activation in 60 s or in the past; only a stale "current multiplier" argument or another caller reverts. Observed notice: 0 to ~4 hours (AAPLx, five updates) | `eth_call` simulation; `MultiplierUpdated`, `MultiplierScheduled` logs |

The xStocks docs' wrapper example (10 tokens at multiplier 1.1 mint 11 wrapped tokens) does not match the code, which mints 10. The code is authoritative.

## Dinari and Ondo on Arbitrum (read on-chain 2026-11-02)

| ID | Status | Finding | Evidence |
| --- | --- | --- | --- |
| DN-1 | Info | Production `DShareFactory` `0xB4Ca…03b8` emitted 251 `DShareAdded` events (dShare plus wrapped dShare); 238 have supply, 11 wrappers have any supply | `cast logs`, `cast call` |
| DN-2 | **Blocker as is** | The wrapped dShare has `recover(account, amount)`, letting its admin send the wrapper's dShares anywhere (selector present in deployed implementation `0x9941…5dE1`) | `WrappedDShare.sol`; deployed bytecode |
| DN-3 | Issue | Wrapped dShare `totalAssets` is the wrapper's dShare balance (Solady `ERC4626`), so donations and Dinari's dividend deposits move the rate. NVDA `convertToAssets(1e18)` = 15.08e18; USFR 5 shares back 727 dShares | `cast call` |
| DN-4 | Issue | Upgrade beacons for all dShares (`0x1543…dacb`) and all wrappers (`0xad20…f7c5`), and the transfer restrictor, are owned by EOA `0x06B0…60a3`. The deployed dShare and wrapper don't expose `owner`, `defaultAdmin` or `hasRole`, so the admin of `recover` and `setBalancePerShare` wasn't confirmed | `cast call` |
| DN-5 | Issue | Holdings are concentrated: three EOAs hold ~90% of NVDA, ~98% of MSTR. No Uniswap v3 USDC pool for NVDA | `cast logs`, `cast call` |
| ON-1 | Confirmed | Ondo GM's BSC token addresses (`NVDAon`, `TSLAon`) have no code on Arbitrum, consistent with Ondo's docs | `cast codesize` |

## Blockers and new on-chain logic

| ID | Status | Finding | Minimum change |
|---|---|---|---|
| DIV-1 | **Deferred** (not needed at launch: only reinvesting issuers are listed). Blocker if cash or claim-based dividends are captured later | Stablecoin dividends pushed to the holder, or claimable by the holder, cannot be recovered from an EVK escrow or an unmodified OZ `ERC4626` (`test_stablecoinDividendIsStuck`). EVK has no token-recovery or arbitrary-call path (from EVK design and `scale:docs/ARCHITECTURE.md:89-97`; not yet tested on local EVK, see B4). | New **dividend-capture wrapper**: OZ `ERC4626` (`decimalsOffset = 0`, seed deposit) plus `sweep(token)` for any token except the underlying, sending to an immutable reserve, and `claim(target, data)` limited to an operator and allowlisted distributors (never the underlying or the wrapper), with a post-call check that the underlying balance did not drop and re-entry blocked. A test-only prototype (`eval/prototypes/DividendCaptureWrapper.sol`, about 60 lines of logic) passes all 8 tests in `eval/dividends/`, including hostile and re-entering distributors, and prices unchanged through the v1 adapter and `EulerRouter`. Production version needs its own spec and audit. Only needed for issuers with cash or claim-based dividends. |
| PATH-2 | Issue, configuration rule | With the stock `EulerRouter`, resolving the wrapper to the rebasing token and pricing the token makes collateral value jump with the multiplier on-chain, while the push oracle still holds the pre-split price: 2× overvalued at a 2:1 split until the next push, 3× at 3:1, and the 3:1 correction (−66.7%) cannot pass a 5000 bps breaker (`test_B7_path2_resolvingToRebasingToken_overvaluesAtActivation`). Euler's own xStocks adapter avoids this by reverting around activation (`lib/euler-price-oracle/src/adapter/chainlink/ChainlinkInfrequentXStocksOracle.sol:18-22`); the v1 oracle has no cheap equivalent, since pause wipes price state. Pricing the wrapper share directly is continuous through activation (`test_B7_path1_wrapperShareIsBase_splitIsContinuous`), and a direct route takes precedence over a resolved vault (`test_B7_directConfigTakesPrecedenceOverResolvedVault`). | Config-check script: every rebasing asset has a direct `wrapper/USD → adapter` route and no `govSetResolvedVault(wrapper)`. No contract change. |
| KEEP-1 | Issue, workaround | Single `keeper` address (`PoppieEulerOracle.sol:24,35-38`). Losing the key stops pricing until the admin calls `setKeeper` (`:226-230`). | No contract needed at launch: several keeper processes share one KMS key, and the Oracle Safe calls `setKeeper` for failover (instant). Optional later: a keeper Safe with Zodiac Roles, or a small keeper forwarder (new contract). |

| PAUSE-1 | Issue, new contract | Issuers pause assets on schedule (Ondo: 20 min, 00:52–01:12 UTC weekdays, `ASSET_PAUSED`, daily share-multiplier update). v1 cannot pause and resume on a schedule: `pauseAssets` erases the price (`PoppieEulerOracle.sol:135-138`), and resuming needs `adminSetPrice` (`:95-97`). EVK hooks can: a hook target is called with the original calldata plus caller and may revert (`Base.sol` `invokeHookTarget`); ops are bit flags (`Constants.sol`: `OP_DEPOSIT`…`OP_SKIM`). Liquidation seizes via the escrow's `transfer` (`OP_TRANSFER`), so leaving that op unhooked keeps liquidations open | `ScheduledPauseHook` (~80 lines, owner `MS_OPS`), hooked on deposit, mint, withdraw, redeem and skim of each escrow; alerts matched to issuer schedules. No v1 change |

No finding requires modifying `PoppieEulerOracle` or `PoppieEulerAdapter`.

## Splits, rebases and dividends

### Per-issuer mechanics (C)

| Issuer | Balance model | Splits | Dividends | Wrapper | Arbitrum | Status |
|---|---|---|---|---|---|---|
| **xStocks** | EVM `balanceOf()` rebases when the multiplier changes; constant `sharesOf()`; `getCurrentMultiplier()` | Multiplier change; takes effect at 00:30 UTC the day after the ex-date; issuer recommends pausing ±15 min | Reinvested via the multiplier | Issuer ERC-4626. **Current** version only: v1 wrapper is donation-manipulable and the issuer says not to use it as collateral | Listed as an EVM chain in the docs | Issue, workaround: hold the current wrapper |
| **Dinari** | Token balance-per-share rebases on splits | Forward and reverse; trading halts; reverse splits may pay USD+ for fractions | Raw dShare: USD+ paid only to wallets registered to a KYC'd entity. Wrapped dShare: reinvested as dShares | Issuer wrapped dShare | Arbitrum (42161) listed as supported for dividends | Needs external info: can a contract wallet be registered? |
| **Ondo GM** | Static balances; total-return tracker (dividends reinvested, net of withholding) | Reflected in the per-token price | Reinvested | Not needed | **Not listed**: docs say Ethereum, BNB Chain, Solana (plus HyperEVM and Robinhood Chain via bridge) | Needs external info |
| **Reality, others** | Not researched | | | | | Needs external info |

Sources: https://docs.xstocks.fi/developers/multipliers.md, https://docs.xstocks.fi/developers/wrapped-xstocks.md, https://docs.dinari.com/docs/dividend-payments.md, https://docs.dinari.com/docs/stock-split-handling.md, https://docs.ondo.finance/ondo-global-markets/overview

### Dividend handling options

| Delivery | Example | Handling | Protocol revenue |
|---|---|---|---|
| Reinvested (multiplier or total return) | xStocks, Ondo, Dinari wrapped | None; value goes to depositors through the share price | No |
| Stablecoins pushed to holder | Dinari raw dShare (if the contract is KYC-registered) | Dividend-capture wrapper, `sweep` to the reserve | Yes |
| Must be claimed by holder | Any issuer with a claim distributor | Dividend-capture wrapper, `claim` then `sweep` | Yes |
| Pushed to a plain escrow or OZ wrapper | — | Lost (stuck) | No; do not list this way |

Using captured dividends in borrow parameters: EVK has no per-collateral rate, so a dividend cannot lower a specific borrower's rate on-chain without more contracts. Off-chain uses:
- set LTV buffers above the largest expected dividend, including specials, because the wrapper share drops by the dividend on the ex-date;
- fund the loss reserve;
- replace the dropped origination-fee revenue (D2).

Depositors forgo cash dividends while deposited; this needs disclosure and legal and tax review.

### Corporate-action pricing risk

- The breaker check is a strict `>` against the old price (`PoppieEulerOracle.sol:104`), and the cumulative check uses the same bps maths (`:297`). A −50% push passes a 5000 bps threshold, the single-stock default in `script/ConfigureDev.s.sol:27`.
- Thresholds are capped at 10000 bps (`:162-163`), measured against the old price (`:306-311`). Moves above +100% (reverse split on a per-token price, squeezes, leveraged ETFs) need `adminSetPrice`.
- Tests: `test_split2to1_mispush_passes_afterRotation`, `test_split2to1_mispush_passes_withinWindow`, `test_split3to1_needsAdmin`, `test_reverseSplit1to3_needsAdminEvenAtMaxThresholds`.
- Pricing the wrapper share as equity price × equity per share keeps the on-chain value continuous when the multiplier activates (`test_adapterPricesWrapperShareThroughSplit`, `test_B7_path1_wrapperShareIsBase_splitIsContinuous`). It only stays right if the keeper uses the multiplier in effect at the push block: xStocks multiplier activation (00:30 UTC) is not aligned with when split-adjusted prices start trading. The keeper can read the schedule on-chain through `multiplierUpdates`, as Euler's own xStocks adapter does.
- Wrapping an issuer token in an unmodified OZ `ERC4626` is workable: splits, reverse splits and reinvested dividends are shared pro rata and everyone can exit in full (`test_rebasesAreProRata`); with a 1e18 seed a donation attack costs the attacker the donation and the victim loses only rounding (`test_inflationAttackWithSeed`); and if the issuer token rounds transfers down, each deposit leaks a few wei from existing holders but never causes insolvency (`test_transferDriftIsBounded`, under a modelled rounding rule).

## A. v1 oracle and adapter

| ID | Status | Evidence | Impact at 500 assets | Workaround |
|---|---|---|---|---|
| A1 | Issue, workaround | `PoppieEulerOracle.sol:86-108`; `test_A1_oneBadEntryRevertsWholeBatch`, `test_A1_unconfiguredAssetRevertsBatch` | Any bad entry reverts a whole chunk | Keeper simulates each chunk with `eth_call` and drops failing entries |
| A2 | Issue, workaround | Per-asset thresholds `:180-190`, range 0–10000 bps, cumulative cap must be non-zero (`:159,184`), admin-only. Pass iff `floor(|Δ|·1e4/old) ≤ threshold` (`testFuzz_A2_breakerBoundary`, 10k runs); `test_A2_thresholdBounds` | Monday open or earnings gaps beyond thresholds need admin calls | Size thresholds per class (below 5000 for split-prone names); batch admin calls via Safe MultiSend |
| A3 | Not an issue | Anchor rotates to the new price once the window expires (`:289-294`); `test_A3_freezeThenResumeWithoutAdmin`. A gap beyond the breaker still needs admin (`test_A3_gapBeyondBreakerNeedsAdmin`); inside a window the cap binds cumulatively (`test_A3_cumulativeCapBindsWithinWindow`) | Stop pushing → stale → resume works without admin, within the breaker | Supports closed-market policy A |
| A4 | Issue, workaround | Pause zeroes price state (`:135-138`); recovery needs `adminSetPrice` (`:193`) plus a keeper push; `pauseAssets` reverts on an already-paused entry (`:133`); `test_A4_pauseWipesStateAndNeedsAdminPlusKeeper`, `test_A4_pauseBatchRevertsIfAnyAlreadyPaused` | Mass recovery = hundreds of admin calls | Reserve pause for emergencies; filter already-paused assets; batch via MultiSend |
| A5 | Not an issue | Per-asset override, else the global value; both zero disables; stale when `age > maxAge` (`:61-65`); `test_A5_staleBoundaryAndOverride` | — | Per-asset overrides for halt-prone names |
| A6 | Issue, workaround | One admin with two-step transfer (`:233-250`); one keeper (`:24`); admin can be a contract; admin holds instant price power (`test_A6_adminCanBeAContract_singleKeeper`) | Keeper is a liveness single point of failure | See KEEP-1; Safe plus Zodiac Roles split (D6) |
| A7 | Not an issue | Mapping storage, 2 slots per asset (`IPoppieEulerOracle.sol:7-34`); no loop over all assets; read gas independent of asset count (`test_A7_readIsConstant`). Measured (`test_A7_gas100/250/500`): push 7.1k gas per asset, configure 29.7k, seed via `adminSetPrice` 23.6k | 500 assets: push 3.55M, configure 14.8M, seed 11.8M gas, each under a 32M limit (Arbitrum's limit to be confirmed on the fork) | Chunk pushes anyway for simulation and partial failure; split configure and seed batches |
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
| B7 | Not an issue for the router path; EVK account checks and liquidation still pending | escrow → wrapper (resolved) → wrapper share via the v1 adapter prices correctly, bid = ask, and stale or paused prices revert through the router with the oracle's own error (`test_B7_path1_wrapperShareIsBase_splitIsContinuous`, `test_B7_staleAndPausedPropagateThroughRouter`). See PATH-2 for the path to avoid |
| B8 | Issue, needs human (D5) | The router governor is one address with full power: it can overwrite a live route with any oracle or delete it (`test_B8_governorCanOverwriteAndDeleteLiveRoutes`; `EulerRouter.sol` `govSetConfig`). Limiting it to unset routes needs a governor contract in front, which is new on-chain logic unless evk-periphery provides one (B1) |

**Earn (read from source, `b2fd6e6`):** an Earn vault can raise a strategy's cap only if `EulerEarnFactory.isStrategyAllowed` accepts it: verified by the factory's perspective contract, which Euler controls, or itself an Earn vault. Whether Poppie's hubs pass the Arbitrum perspective must be checked on a fork; if not, lenders deposit into hubs directly. The curator can also allocate (`onlyAllocatorRole` accepts the curator).

**B1–B6, B9, B10: not verified.** This branch has no EVK, EVC (beyond the utility nested in `euler-price-oracle`), evk-periphery or Earn sources. Next step: an EVK harness with the `scale` pins (EVC `a7d3c29`, EVK `422bf24`, evk-periphery `96b83f8`, Earn `b2fd6e6`; `scale:README.md:84-91`), which means adding submodules to this branch.

The highest-priority items:

| ID | Why it matters here |
|---|---|
| B4 | Confirms DIV-1: no token recovery from an escrow, and `skim` semantics for positive rebases |
| B6 | Defines what freezes when one collateral is stale (closed-market policy A). Expected: borrow, withdraw and liquidation revert for accounts using that collateral |
| B7 (rest) | EVK account checks and liquidation with the wrapper share as collateral |
| B3, B5 | Pause and closed-deposit design around corporate actions |

## D. Decisions for a human

| ID | Decision | Findings that bear on it | Recommendation |
|---|---|---|---|
| D1 | Closed-market policy per class | A3 (resume works without admin), B6 (not verified) | Policy A for most names, once B6 confirms scope; LTV buffers sized for Monday gaps |
| D2 | Drop the origination fee | Captured dividends can partly replace it; B10 not verified | Decide after B10 |
| D3 | Allow a Poppie-deployed wrapper | DIV-1; issuer wrappers exist for xStocks and Dinari | Use issuer wrappers for rebasing; allow the dividend-capture wrapper only for cash or claim dividends |
| D4 | Stablecoin-dividend issuers | DIV-1, Dinari KYC requirement | Capture via the wrapper where the issuer allows contract holders; otherwise use reinvesting wrappers; never list with stuck dividends |
| D5 | Listing via Safe or timelock | B8: the router governor can overwrite or delete any live route instantly | Timelock for the router governor; instant listing only through a governor contract that can add but not overwrite, if one exists at the pin (B1) |
| D6 | Delegate `adminSetPrice` | A2, A4, reverse-split path | Delegate to an ops signer with Zodiac Roles, limited to scheduled corporate actions |
| D7 | One oracle instance or several | A7, A11, KEEP-1 | One instance. A7 shows it handles 500 assets; extra instances add admin and keeper addresses to secure. Split only for a concrete need |

## Prioritised actions

| # | Severity | Scope | Action |
|---|---|---|---|
| 1 | High | Contracts | Build and audit the dividend-capture wrapper (DIV-1), if cash or claim dividends are in scope |
| 2 | High | Off-chain | Listing and config check: reject raw rebasing tokens; require current xStocks wrappers (verify `asset()` and version) and Dinari wrapped dShares; every rebasing asset has a direct `wrapper/USD` route and is never a resolved vault (PATH-2) |
| 3 | High | Off-chain | Corporate-action engine: per-share pricing at the effective multiplier, skip pushes within ±15 min of activation, pre-cut borrow LTV and freeze supply caps, flag pushes with deviation ≥ 40% on assets with pending actions |
| 4 | Medium | Off-chain (human) | Confirm Ondo Arbitrum availability, and whether Dinari can register a contract wallet for dividends |
| 5 | Medium | Off-chain | Runbook and pre-built Safe batches for moves above +100% (`adminSetPrice`) |
| 6 | Medium | Tests | EVK harness for B1–B6 and the rest of B7 (needs submodules on this branch), then an Arbitrum fork replay of a real xStocks multiplier change (needs an RPC URL; none is set in this environment) |
| 7 | Medium | Off-chain | Keeper redundancy: shared-key keeper processes with nonce coordination; `setKeeper` failover runbook |
| 8 | Low | Off-chain | Keeper pre-simulation and filtering of already-paused assets |
| 9 | Low | Off-chain | MultiSend JSON generation for per-asset admin setters at 500 assets |
| 10 | Low | Documentation | Risk spec with dividend-yield input per asset; disclosure text for forfeited dividends |
| 11 | Low | Contracts | Separate build profile for new contracts; bytecode check that the oracle and adapter match the v1-bsc build |
