# Static analysis triage (v2)

*POP-17, Nov 2 2026, local `scale` after POP-16. Scope: `src/` (scripts and tests excluded). No contract was changed in response; anything needing a fix would be filed on the owning ticket.*

## Tools and commands

| Tool | Version | Command | Result |
| --- | --- | --- | --- |
| Slither | 0.11.6 (CI pin) | `slither . --config-file slither.config.json --fail-medium` | Exit 0: no high or medium finding. 27 low `calls-loop`, 22 low `timestamp`, 12 informational |
| Aderyn | 0.6.8 | `aderyn . --src src` | 2 "high" (both false positives, below), 10 low categories (style) |

`slither.config.json` filters `lib/`, `test/` and `script/`. CI runs Slither with `--fail-medium` on every PR (required check).

## Slither

| Detector | Impact | Where | Triage |
| --- | --- | --- | --- |
| `calls-loop` | Low | Steward `_govCall`, `_ltv`, `_lowerCapsOne`, `_resolvedCaps`, `_listOne`; oracle `listAssets` (`decimals()`) | By design: batches of up to 500 entries, each calling EVK through the Euler Governor or reading `LTVFull`/`caps`. Every callee is trusted (canonical EVK proxies registered as hubs or escrows, the Poppie Governor). A reverting callee reverts the whole batch, which is the intended all-or-nothing behaviour. Batch gas is measured in `test/bench/StewardGas.t.sol` (500-entry override 16.6M, cut 29.1M, cancel 19.1M). Accepted |
| `timestamp` | Low | Pause expiries (hooks), oracle staleness and spacing, steward ramps and rate limits | Intended: every time rule in the spec is a timestamp comparison. Sequencer timestamp drift on Arbitrum is seconds against limits of minutes to days. Accepted |
| `assembly` | Info | Fee router `_tload`/`_tstore`; steward `_govCall` revert bubbling | Reviewed. Transient storage is the spec's mechanism (`PoppieFeeRouter`); `_govCall` only re-throws revert data. Accepted |
| `low-level-calls` | Info | Steward `_govCall` | `GovernorAccessControl` reads the target from the last 20 calldata bytes, so a typed call is impossible. Revert data is bubbled. Accepted |
| `costly-loop` | Info | Oracle `_pushOne`, `_confirm` (`delete` in loop) | Clearing pending fields per entry; measured in `test/bench/PushGas.t.sol`. Accepted |
| `cyclomatic-complexity` | Info | Steward `_raiseOne` | Readability only. Covered by boundary tests. Accepted |
| `naming-convention` | Info | `IPoppieFeeRouter.MAX_FEE_BPS`, `IPoppieEulerAdapter.USD` | Interface constants fixed by POP-5. Accepted |

Medium findings raised and fixed while writing the steward (POP-11), before commit: `incorrect-equality` on a timestamp-derived `remaining == 0` (replaced by an explicit `ramping` flag), `reentrancy-no-eth` (storage pointer reassigned after the Governor call; now a memory copy, plus a transient reentrancy guard on every mutating entry point), `uninitialized-local` (explicit zero).

## Aderyn

| ID | Finding | Where | Triage |
| --- | --- | --- | --- |
| H-1 | State change after external call | `PoppieEulerOracle.listAssets` (reads `decimals()` before writing the asset record) | False positive. `listAssets` is `MS_OPS` only; a token re-entering would call as itself, without the role. The write sequence is per token and add-only. No action |
| H-2 | Storage array edited with memory | `PoppieEulerOracle.getQuoteData`, `haircutBps` (pass `_params` to a memory parameter) | False positive: the callee only reads. No action |
| L-1 | Centralization risk | Role-gated functions | By design (see `docs/SECURITY.md`, roles and trust) |
| L-2 | Costly operations inside loop | Batched setters | Same as Slither `calls-loop` / `costly-loop` |
| L-3, L-4 | Large literal; literal instead of constant | Steward class ceilings, defaults | Style. The class table is the spec's, in one function |
| L-5 | PUSH0 | All | Target is Arbitrum (Cancun), which supports PUSH0. Accepted |
| L-6 | `require`/`revert` in loop | Batched functions | Intended all-or-nothing batches |
| L-7 | Unchecked return | `_grantRole`/`_revokeRole` (OZ bool), steward `_checkCapInput` in raise/override (only the checks are needed), wrapper `_pullAndMint` in `mint`, factory seed `deposit` | Reviewed; each ignored value is unused by design (the factory case is annotated in code) |
| L-8 | Uninitialized local | Loop counters | Style |
| L-9 | Unspecific pragma | `src/interfaces/*` (`^0.8.24`) | Intended: interfaces are consumable by integrators; implementations pin `0.8.24` |
| L-10 | Unused error | Interface errors reserved by the spec | Interface fixed by POP-5. No action |

## Not covered by static analysis (for the audit)

- Steward ramp arithmetic mirrors EVK `LTVConfigLib.getLTV` (`_ramped`); its agreement with EVK is checked by unit tests and the Arbitrum fork tests, not by tooling.
- AmountCap encode/resolve (steward and scripts) is fuzzed (`testFuzz_encodeCapDown`).
- Cross-contract assumptions (hook ↔ router wiring, escrow governance, router routes) are checked by `script/ConfigCheck.s.sol`, not on chain.
