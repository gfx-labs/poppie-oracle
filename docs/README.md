# Docs

Poppie v2 on Arbitrum has two candidate designs. Both keep the audited v1 oracle and adapter and every stock Euler contract unchanged, and both are organized around risk management: what can go wrong, which levers bound it, and what each design cannot do. Start with `Overview.md` (shared plan) and `Design-Comparison.md`.

| Folder | Contents |
| --- | --- |
| `zeroContracts/` | **Zero-contract design**: no new Poppie contracts. Its plan (risk register, levers, governance and everything else design-specific) and a one-page overview |
| `peripheralContracts/` | **Peripheral-contract design**: the same core plus five small Poppie contracts in existing slots (hooks, oracle admin and keeper, router governor). The full plan, a one-page overview and the contract specifications |
| `issuerResearch/` | Per-issuer research and questions (xStocks/Backed, Robinhood, Reality, Enso), the issuer overview and the HONx incident |

Shared, in this folder:

| File | Contents |
| --- | --- |
| `Overview.md` | **The shared plan**: everything identical in both designs (how it works, asset classes, issuers, hubs, liquidity policy, prices and corporate actions, shared monitoring, decisions, blockers, open gaps) |
| `Design-Comparison.md` | Gap-by-gap comparison: what each design bounds, what neither can, what each saves or costs |
| `Risk-Metrics.md` | Risk metrics, with enforcement in each design |
| `EVAL_FINDINGS.md` | Evaluation findings and test evidence (both designs) |
| `Poppie-Team-Questions.md` | Questions for the Poppie team about the BSC keeper and market |

`legacy/` holds superseded material: the original evaluation brief (`Design.md`), the BSC threat model of the v1 oracle and adapter (`SECURITY.md`), and the earlier plan from the tabled ground-up rebuild.
