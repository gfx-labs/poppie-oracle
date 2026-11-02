# Audit scope (v2)

Tracks follow `docs/ARCHITECTURE.md` §Audits. Commit: the `scale` head at audit kickoff (solc 0.8.24, Cancun, optimizer 200 runs).

## Smart contracts (in scope)

| File | Contract | nSLOC | Focus |
| --- | --- | --- | --- |
| `src/oracle/PoppieEulerOracle.sol` | Price store and state machine | 359 | State transitions (Live / Unconfirmed / Closed), class bounds, `n`-push fallback and `minPendingSpacing`, confirm/confirmBatch, packed push decoding, pause semantics |
| `src/oracle/PackedPrices.sol` | Packed push codec | 18 | 14-byte entries, id 0 rejected |
| `src/oracle/PoppieEulerAdapter.sol` | Three-state `IPriceOracle` | 60 | bid ≤ mid ≤ ask, mid reverts when not Live, bid ≤ L(1−h) before confirmation, rounding |
| `src/fee/PoppieFeeRouter.sol` | Origination fee | 88 | Transient pending accounting, `forward` via EVC only, router never holds funds, fee rounding |
| `src/hooks/PoppieHubHook.sol`, `src/hooks/HookOps.sol` | Hub hook | 106 | Borrow validation, status-check gate, liquidation and borrow pauses, flash-loan block |
| `src/hooks/PoppieEscrowHook.sol` | Escrow hook | 80 | Every deposit route blocked when Closed or paused; `controlCollateral` bypass; wrapper resolution |
| `src/wrapper/PoppieBalanceWrapper.sol` | Balance wrapper | 95 | Rebases pro rata, inflation resistance (offset 6 + seed), `sweep` never moves the underlying |
| `src/wrapper/PoppieWrapperFactory.sol` | Wrapper factory | 42 | CREATE2 per token, seed handling, dividend recipient |
| `src/governance/PoppieRouterGovernor.sol` | EulerRouter governor | 89 | Add-only routes, escrow verification, approved-token list, timelocked `execute` |
| `src/steward/PoppieRiskSteward.sol` | Risk steward | 478 | Class ceilings and gap rule, ramp preservation and chain baselines, rate limits, blue-chip sync, override / ramp cancel, demote / promote, AmountCap handling |
| `src/access/*` | Shared roles | 32 | `MS_OPS` revoke-only power over `K_*`, bootstrap |
| `src/interfaces/*` | Interfaces | — | Reference |

Total in-scope implementation: about 1,450 nSLOC (non-blank, non-comment lines).

Configuration in scope (review, not code): `script/Deploy.s.sol` role wiring and hub parameters, `script/BuildListingBatch.s.sol` listing flow, `script/ConfigCheck.s.sol` coverage, the reserve Safe Roles-module scope (`test/fork/LaunchRehearsal.t.sol`).

## Out of scope

Euler core and periphery at canonical Arbitrum addresses (EVC, EVK factory/implementation, EulerRouter, `GovernorAccessControl`, kink IRM, Euler Earn, lenses), OpenZeppelin, Safe and Zodiac Roles. Their versions are pinned (README "Dependencies") and the constraints Poppie relies on are re-verified on an Arbitrum fork (`test/fork/EulerCompat.t.sol`).

## Off-chain systems (separate track)

KMS policies and account separation; the keeper (packed push, chunking, paused-asset filtering); the `K_CONFIRM` service and whether its checks are independent of the keeper; the risk engine; alerting (cap-raise alert required before `K_LOOSEN` moves to a KMS key).

## Economic (separate track)

Class and band thresholds, LTV ceilings (note the M2/M3 ceiling gap vs the 8-pt gap rule, `CONTRACT_SPEC.md` §8), launch LTVs, cap formulas, haircut sizing against weekend and halt gaps, origination and interest fees, IRM curves (placeholders in `config/`).

## Known issues and accepted risks

See `docs/SECURITY.md` ("Residual risks") and `CONTRACT_SPEC.md` §8. Static analysis triage: `docs/STATIC_ANALYSIS.md`.

## Test evidence

`forge test --no-match-path "test/fork/**"` (unit, fuzz, invariant, symbolic, integration, scripts, bench) and `forge test --match-path "test/fork/**" --fork-url arbitrum` (canonical Euler compatibility, scale, launch rehearsal).
