# Docs

v2 (Arbitrum, Euler V2) design documents. v1 (BSC) lives at the `v1-bsc` tag.

**Branch policy:** all v2 work happens on the `scale` branch, and every PR is a draft PR targeting `scale`. `main` matches BSC production and is not changed.

| Document | Role |
| --- | --- |
| `ARCHITECTURE.md` | Design intent. Authoritative for what the system does and why. |
| `V2_PLAN.md` | Approved v2 build plan (§0-§9). Wins over the spec for v2 design intent; cited by section number in the Linear tickets. |
| `OPEN_QUESTIONS.md` | Design questions and their Oct 27 2026 resolutions. |
| `CONTRACT_SPEC.md` | Contract interfaces and invariants. Wins for interfaces; reconciled with the code before audit (POP-17). |
| `SECURITY.md` | v1 threat model; rewritten for v2 before audit (POP-17). |

## Superseded

`Poppie-Arbitrum-Hub-Architecture-Governance-Plan.pdf` (the original plan) is superseded by `ARCHITECTURE.md`, which is its Markdown conversion and is newer (it adds §Issuers, the balance wrapper and the Oct 27 decisions). The PDF is not kept in the repo.
