# Docs

v2 (Arbitrum, Euler V2) design documents. v1 (BSC) lives at the `v1-bsc` tag.

**Branch policy:** all v2 work happens on the `scale` branch through PRs that pass CI (see `AGENTS.md` for auto-merge and the draft rule for spec deviations). `main` matches BSC production and is not changed.

| Document | Role |
| --- | --- |
| `ARCHITECTURE.md` | Design intent. Authoritative for what the system does and why. |
| `V2_PLAN.md` | Approved v2 build plan (§0-§9). Wins over the spec for v2 design intent; cited by section number in the Linear tickets. |
| `OPEN_QUESTIONS.md` | Design questions and their resolutions (Oct 27 to Nov 2 2026). |
| `CONTRACT_SPEC.md` | Contract interfaces, behaviour and implementation decisions. Wins for interfaces; reconciled with the code (POP-17); open decisions in §8. |
| `SECURITY.md` | v2 threat model, roles and trust, residual risks. |
| `RUNBOOKS.md` | Operational procedures: corporate actions, loss reserve, key leaks, mass restore, dividend sweep, listing. |
| `AUDIT_SCOPE.md` | Audit tracks and in-scope files. |
| `STATIC_ANALYSIS.md` | Slither and Aderyn triage. |

## Superseded

`Poppie-Arbitrum-Hub-Architecture-Governance-Plan.pdf` (the original plan) is superseded by `ARCHITECTURE.md`, which is its Markdown conversion and is newer (it adds §Issuers, the balance wrapper and the Oct 27 decisions). The PDF is not kept in the repo.
