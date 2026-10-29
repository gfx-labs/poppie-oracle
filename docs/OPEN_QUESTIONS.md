# Open questions (v2)

*All questions below were decided on Oct 27 2026; the resolutions are recorded as given. The decisions are folded into `docs/V2_PLAN.md`, `docs/ARCHITECTURE.md` and `docs/CONTRACT_SPEC.md`. Q1 and Q2 are flagged for human review before launch (Linear POP-19 and POP-20).*

## Blocks ticket creation / contract code (all resolved)

- [x] **Q1. Who funds seed deposits?** The wrapper factory and escrow creation both need seed tokens. Does the MS_OPS Safe hold them, or does a deployer key create the wrapper and escrow ahead of the Safe batch? *Blocks: balance wrapper, scripts.*
  - **Resolution:** a KMS-backed deployer key creates the wrapper and escrow ahead of the MS_OPS Safe batch (option B). Flagged for review before launch (POP-19).
- [x] **Q2. Distributing tokens:** wrap them with a claim mechanism, or don't list them yet? (`ARCHITECTURE.md` §Issuers: default is that users forgo stablecoin dividends while deposited; it doesn't say what happens to stablecoins that arrive at the escrow vault or wrapper address.) *Blocks: balance wrapper, scripts.*
  - **Resolution:** wrap them. The wrapper receives the dividends, and a permissionless `sweep(token)` sends them (never the underlying) to a recipient stored in the factory, the reserve Safe, changeable only by MS_ADMIN via the timelock. Depositors forgo dividends while deposited, disclosed at deposit. Documented in `ARCHITECTURE.md` §Issuers. Flagged for review before launch (POP-20).
- [x] **Q3. Undo semantics:** which value is saved when there are several tightenings, or a loosening in between? Does `restore` cover liquidation LTV, and does it cancel a ramp that is still running? *Blocks: risk steward.*
  - **Resolution:** undo is replaced by a bounded override. MS_OPS can set borrow LTVs and caps anywhere up to the class ceilings (caps: each asset's cap ceiling), in batches, without the weekly limit. Plus a ramp cancel for liquidation-LTV cuts still in progress, restoring the liquidation LTV in force before the first cut of the chain.
- [x] **Q4. `demote` into the band hub:** a blue chip falling to long tail stays in its band hub, but the ceiling there is lower (75 -> 58 liquidation LTV for M1), a cut larger than 5 pts. Which limits apply in that hub? *Blocks: risk steward.*
  - **Resolution:** the demotion rules apply in the band hub too.
- [x] **Q5. What counts toward "<= 10 assets per 24h":** a synced blue-chip cut changes 4 hubs. Does that count as 1 or 4? *Blocks: risk steward.*
  - **Resolution:** the budget is removed, provided MS_OPS can cancel liquidation-LTV ramps.
- [x] **Q6. "+25% per 7 days":** fixed baseline or rolling? Caps are stored in EVK's lossy AmountCap encoding, so the comparison rule needs a definition. *Blocks: risk steward.*
  - **Resolution:** the 25% limit is cut entirely. Per-asset cap ceilings must be conservative, because they become the only on-chain limit on cap growth. An alert must exist for cap raises. (MS_OPS may raise ceilings instantly.)
- [x] **Q7. Rollout phase 1 ("steward can only tighten"):** done just by not granting `K_LOOSEN`, or does it need an on-chain switch? *Blocks: risk steward.*
  - **Resolution:** `K_LOOSEN` is assigned to MS_OPS for phase 1. No on-chain switch.
- [x] **Q8. Pause durations:** (a) `K_GUARD` cooldown length; (b) can MS_OPS chain liquidation pauses back to back; (c) does the escrow deposit pause have the same cooldown as the borrow pause? *Blocks: fee router + hub hook, escrow hook.*
  - **Resolution:** (a) no cooldown, to avoid on-chain locks and friction in normal operations; (b) chained liquidation pauses are fine; (c) same rules, for simplicity.
- [x] **Q9. Fee receivers:** is the origination-fee treasury the same address as each hub's interest-fee receiver, or a different one? *Blocks: fee router + hub hook, scripts.*
  - **Resolution:** the same address. The router reads `hub.feeReceiver()`; no `setTreasury`.
- [x] **Q10. Exposure caps per issuer and underlying stock:** on-chain (steward) or off-chain only? *Blocks: risk steward.*
  - **Resolution:** off-chain only.

## Interface decisions (POP-5, resolved Oct 28 2026)

Raised while fixing the interfaces in `src/interfaces/`. All folded into `CONTRACT_SPEC.md`, `V2_PLAN.md` and `ARCHITECTURE.md`. The bias throughout: less code, fewer on-chain restrictions, fewer timelocks, less human work.

- [x] **Q13. Steward batching.** The spec rows said "batched" but showed scalar signatures.
  - **Resolution:** every mutating steward function except `promote`, `demote` and `addHub` takes an array of structs; one call is one batch (up to 500). A single change is a length-1 array.
- [x] **Q14. `demote` arguments.** `demote(asset)` can't know the target class or band hub, and several hubs may share a band.
  - **Resolution:** `demote(asset, newClass, bandHub)`; `bandHub` must be registered in band `newClass` (`WrongBand`).
- [x] **Q15. Steward hub registry.** The steward stores the hub list and bands but had no setter.
  - **Resolution:** `addHub(hub, band)`, role `DEFAULT_ADMIN_ROLE`, mirroring the hub hook's `registerHub`.
- [x] **Q16. Cap ceiling encoding, and hub-level caps** (spec §8).
  - **Resolution:** ceilings use the same raw 16-bit AmountCap as caps (never raw 0), and are stored **per vault**, so hubs get ceilings too. `setCapCeiling` takes supply and borrow ceilings. Hub caps follow the escrow rules: `MS_OPS` sets ceilings, `K_LOOSEN` raises up to them, `K_TIGHTEN` lowers, `MS_OPS` overrides.
- [x] **Q17. Oracle risk params and the timelock.** The spec put the class haircut, price class, `maxPriceAge`, `n` and `minPendingSpacing` behind the 48h timelock, which conflicted with "no timelock on risk params" and lagged steward demotions by 48h.
  - **Resolution:** all five setters are `MS_OPS`, instant, with hard bounds only (haircut <= 10,000 bps, `n >= 2`, non-zero durations). One setter per param; events `AssetClassSet`, `ClassHaircutSet`, and `ParamsUpdated(maxPriceAge, n, minPendingSpacing)` as a snapshot. `PriceState` is `Closed = 0, Unconfirmed, Live` so an unset state fails closed. Prices are `uint128` in the ABI and `uint96` in the packed format.
- [x] **Q18. Wrapper minimum seed.** A factory-wide raw-unit minimum doesn't work across decimals.
  - **Resolution:** dropped. `createWrapper(token, seedAmount)` requires only `seedAmount > 0`; the virtual share offset handles first-depositor inflation.
- [x] **Q19. Who ends a `K_GUARD` pause early** (spec §8).
  - **Resolution:** `MS_OPS`, via `unpauseBorrows`, `unpauseDeposits` and `unpauseLiquidations`. All pause and unpause functions take arrays of vaults so one call covers every hub or escrow.
- [x] **Q20. `promote` hub list.** Passing every hub only added a failure mode.
  - **Resolution:** `promote(asset)` uses the stored hub list.
- [x] **Q21. Hook <-> router circularity.**
  - **Resolution:** no setter. Both addresses are immutable; the deploy script precomputes the CREATE address and asserts it (POP-9).
- [x] **Q22. Role bootstrapping.** With the timelock as the only admin, launch role grants would each wait 48h.
  - **Resolution:** `PoppieAccessControl(initialAdmin)`. The deploy script passes the deployer key, grants every role, registers hubs, then grants `DEFAULT_ADMIN_ROLE` to the timelock and renounces. The configuration check fails if the deployer keeps any role.
- [x] **Q23. Dependency pins and test harness.**
  - **Resolution:** evk-periphery `96b83f8` (its EVC/EVK/Earn gitlinks match the deployed contracts; the newer `b54367e` does not); top-level OpenZeppelin `69c8def` (v5.1.0); `optimizer_runs = 200`, since Euler contracts are used at their canonical addresses and only Poppie bytecode depends on it. The local harness uses `GovernorAccessControl` and zero Permit2 / balance tracker; fork tests use the real Permit2.

## Deferred

- [ ] **Q11. Issuer-freeze monitoring in the fork rehearsal:** no monitoring exists in this repo. Should the fork test only assert the on-chain symptom, with monitoring tracked as a separate off-chain ticket? *Blocks: fork rehearsal (test scope only).*
  - **Resolution:** not for now; too much detail. The fork test asserts the on-chain symptom only.

## Resolved

- **Q12. PDF readability:** some agents can't read PDFs. Resolved by `docs/ARCHITECTURE.md` (Markdown conversion; newer than the PDF).

