# Docs

Poppie v2 on Arbitrum has two candidate designs: **zero-contract** (no new Poppie contracts) and **peripheral-contract** (the same core plus five small Poppie contracts). Start with `Overview.md`.

| File | Contents |
| --- | --- |
| `Overview.md` | Executive comparison of the two designs: risk trade-offs, costs, recommendation, decisions needed |
| `zeroContracts/Overview.md` | One-page summary of the zero-contract design |
| `zeroContracts/Design.md` | **Baseline design**, with everything both designs share: hubs, issuers, risk register and metrics, liquidity policy, prices and corporate actions, governance, monitoring, decisions, blockers, open gaps |
| `peripheralContracts/Overview.md` | One-page summary of the peripheral-contract design |
| `peripheralContracts/Design.md` | What the peripheral design changes, and the specifications of contracts P1–P5 |
| `Poppie-Team-Questions.md` | Questions for the Poppie team about the BSC keeper and market |
| `issuerResearch/` | Per-issuer research and findings (`xStocks.md`, `Robinhood.md`, `Reality.md`, `Dinari-Ondo.md`), a one-page issuer comparison, questions for issuers and Enso, and the HONx incident |
| `evaluation/` | Evidence from testing: `Contracts.md` (v1 oracle and adapter, stock Euler, tests and how to run them) and `Keeper.md` (keeper prototype) |
| `legacy/` | Superseded material: the original evaluation brief, the BSC threat model and the earlier rebuild plan |

Findings are cited by ID across the docs: XS, RH, RE, DN, ON in `issuerResearch/`; KEEP in `evaluation/Keeper.md` (KEEP-1 in `Contracts.md`); A, B, DIV, PATH, PAUSE in `evaluation/Contracts.md`.
