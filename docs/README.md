# Docs

Poppie v2 on Arbitrum has two candidate designs: **zero-contract** (no new Poppie contracts) and **peripheral-contract** (the same core plus five small Poppie contracts). Start with `Overview.md`.

| File | Contents |
| --- | --- |
| `Overview.md` | Executive comparison of the two designs: risk trade-offs, costs, recommendation, decisions needed |
| `zeroContracts/Overview.md` | One-page summary of the zero-contract design |
| `zeroContracts/Design.md` | **Baseline design**, with everything both designs share: hubs, issuers, risk register and metrics, liquidity policy, prices and corporate actions, governance, monitoring, decisions, blockers, open gaps |
| `peripheralContracts/Overview.md` | One-page summary of the peripheral-contract design |
| `peripheralContracts/Design.md` | What the peripheral design changes, and the specifications of contracts P1–P5 |
| `issuerResearch/` | Per-issuer research and findings (`xStocks.md`, `Robinhood.md`, `Reality.md`, `Dinari-Ondo.md`, which also holds the BSC findings and questions for the Poppie team), a one-page issuer comparison, questions for issuers and Enso, and the HONx incident |
| `evaluation/` | Evidence from testing: `Contracts.md` (v1 oracle and adapter, stock Euler, tests and how to run them) and `Keeper.md` (keeper prototype) |
| `legacy/` | Superseded material: the original evaluation brief, the BSC threat model and the earlier rebuild plan |

IDs used across the docs:

- **Findings:** XS, RH, RE, DN, ON in `issuerResearch/`; KEEP in `evaluation/Keeper.md` (KEEP-1 in `Contracts.md`); A, B, C, DIV, PATH, PAUSE in `evaluation/Contracts.md`.
- **Decisions (D1–D19):** `zeroContracts/Design.md`, "Decisions"; the peripheral design overrides some in `peripheralContracts/Design.md`.
- **Gaps between the designs (G1–G12):** `Overview.md`.
- **Risk metrics (R1–R10):** `zeroContracts/Design.md`, "Risk metrics".
- **Peripheral contracts (P1–P5):** `peripheralContracts/Design.md`, "Contract specifications".

The keeper code is in the oracleSystem repo, branch `v2` (`V2.md` there).
