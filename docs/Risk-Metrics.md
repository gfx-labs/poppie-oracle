# Risk metrics

*Nov 16, 2026. Shared by both designs: zero-contract (`docs/zeroContracts/Poppie-Arbitrum-Hub-Architecture-Governance-Plan.md`) and peripheral-contract (`docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`). The metrics are the same; what enforces them differs, shown in the last two columns. Comparison: `docs/Design-Comparison.md`.*

## Why these metrics: the Kelp/Aave case

From news coverage (April–May 2026; the court filings were not read):

- On 18 April 2026 an attacker broke KelpDAO's LayerZero bridge for rsETH and released about $292M of rsETH with nothing behind it. Reports say compromised RPC nodes were used.
- The attacker posted that rsETH on Aave as collateral and borrowed about $230M of real ETH from Aave's lenders. Up to $13B left DeFi in the following days.
- Arbitrum's Security Council froze 30,766 ETH (about $71M) held by the attacker. Arbitrum DAO voted to move it to a recovery multisig.
- On 1 May, holders of $877M in terrorism judgments against North Korea filed a restraining notice, arguing the ETH was North Korean (Lazarus) property. Aave argued the attribution is unproven and that the funds belong to the users who lost them. Around 8 May a New York federal judge let the transfer proceed, with the claim following the funds.

What it shows for Poppie:

1. **Collateral can look real and not be.** Poppie's prices come from the stock price, so an unbacked token prices like a real one. Routes: a stolen issuer minter key, an issuer upgrade, or a bridged token.
2. **The loss happens in minutes.** A Safe takes minutes to hours to sign. What bounds the loss is what was set in advance: caps and borrow headroom.
3. **Stolen funds bring legal claims.** Recovered or frozen funds can be contested in court for months.
4. **Signer compromise is the other large route.** Lazarus took $1.5B from Bybit in 2025 by deceiving its Safe signers.

## Metrics

| # | Metric | Formula | Target | Zero-contract enforcement | Peripheral enforcement |
| --- | --- | --- | --- | --- | --- |
| R1 | Unbacked-collateral loss, per issuer | Σ over the issuer's names of (escrow supply cap × price × highest borrow LTV), capped at the borrowable cash of the hubs that list them | ≤ L_issuer | Supply caps **[Policy]** | Same |
| R2 | Loss before Poppie can respond | Σ over hubs of the USDC that can be borrowed before a response lands: (borrow cap − current borrows) in the zero-contract design; the hourly borrow limit × response time in the peripheral design | ≤ L_event | Borrow-cap headroom, kept tight and raised daily by Euler's `CapRiskSteward` | Hourly borrow limit in the hub guard (P1) |
| R3 | Reserve coverage | Loss reserve ÷ max(R1 for the largest issuer, R2) | ≥ 1 | Policy and alert | Same |
| R4 | Bridged-token exposure | Value of collateral that is a bridged representation of the issuer's token | 0 at launch | Listing rule **[Policy]** | Same |
| R5 | Liquidatable debt vs exit depth | Per name and session: debt of accounts below liquidation LTV ÷ exit depth in that session | ≤ 1, alert above 0.5 | Caps sized to exit depth; alert | Same |
| R6 | Lender liquidity | Hub utilization; USDC Earn lenders can withdraw now | Utilization below the IRM kink most of the time | Interest-rate model; alert | Same |
| R7 | Account concentration | Largest single owner's share of a hub's debt (sub-accounts grouped by EVC owner) | ≤ C_account | Alert only | Optional debt cap per account in the hub guard (easy to split across addresses) |
| R8 | Time to freeze | Time from alert to a borrow freeze landing on-chain | ≤ T_freeze | Drilled; an emergency key on Euler's emergency governor makes it seconds | Guardian pause in the hub guard: seconds |
| R9 | Sanctions matches | Deposits, borrows or receivers on the Chainalysis list or Poppie's denylist | 0 | App and SDK screening; monitoring | Hook screening on borrow and deposit, plus the same |
| R10 | Oracle admin exposure | Largest price move the oracle admin can make without delay | Bounded | None: the Oracle Safe can set any price, unless its admin is a timelock, which delays every admin action (D13) | Oracle admin guard (P3): ±X% instant, larger moves delayed |

`L_issuer`, `L_event`, `C_account` and `T_freeze` are Poppie's risk appetite and are **not set yet**. They have to come from Poppie: the largest loss it will accept from one event, as dollars or a share of lender deposits, and the target size of the loss reserve.

## Worked example (illustrative)

Caps are sized to exit depth in the weakest priced session (blue chip 20%, long tail 10%). With Backed's stated sizes (up to $1M per trade on majors in market hours; about $10k on long-tail names overnight):

- **Blue chip priced only in market hours:** cap ≈ 20% × $1M = $200k of collateral; at 70% borrow LTV, about $140k of borrowing per name.
- **Long-tail name priced overnight:** cap ≈ 10% × $10k = $1k. That is too small to be worth listing, so long-tail names should be priced only in sessions where Backed quotes larger sizes. This needs Backed's per-session sizes (`docs/issuerResearch/xStocks-Backed-Questions.md`, Q10–Q11).
- **R1 for xStocks** with 20 blue chips at $200k: about $2.8M of borrowing if every xStocks token were unbacked at once.
- **R2** in the zero-contract design is the sum of borrow-cap headroom across 4 hubs. Keeping each hub's headroom at, say, $250k bounds a fast attack to $1M, at the cost of a daily cap raise.

## Data and alerts

- R1, R2, R5, R6 and R7 come from EVK lens reads plus oracle prices; compute them in the v2 monitor every run.
- R8 is measured in drills; record each drill.
- R9 comes from screening logs and the Chainalysis oracle on Arbitrum (`0x40C57923924B5c5c5455c48D93317139ADDaC8fb`, the same list xStocks tokens use).
- Alert when any metric is above 80% of its target; page above 100%.
