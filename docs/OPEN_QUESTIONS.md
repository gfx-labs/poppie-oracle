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

## Deferred

- [ ] **Q11. Issuer-freeze monitoring in the fork rehearsal:** no monitoring exists in this repo. Should the fork test only assert the on-chain symptom, with monitoring tracked as a separate off-chain ticket? *Blocks: fork rehearsal (test scope only).*
  - **Resolution:** not for now; too much detail. The fork test asserts the on-chain symptom only.

## Resolved

- **Q12. PDF readability:** some agents can't read PDFs. Resolved by `docs/ARCHITECTURE.md` (Markdown conversion; newer than the PDF).
