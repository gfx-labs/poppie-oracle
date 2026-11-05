# Questions for Reality (rTokens on Arbitrum)

*Nov 5, 2026 (UTC; updated after the 11-05 splits and Tenderly traces). No contact yet; to send once there is one. Poppie is evaluating rTokens as collateral in Euler V2 lending markets on Arbitrum. Our escrow vault would hold the rToken itself, and we would price each token as equity price × `uiMultiplier()`. Reality's docs are geo-blocked from where we ran this. We read the Dividends & Claiming page through a VPN and take it at its word. Everything else comes from Bitget's public posts and on-chain data. The token contracts are unverified, so we read behaviour from events and simulated calls (findings RE-1 to RE-12 in `docs/EVAL_FINDINGS.md`).*

**Status key:** **On-chain** means answered on-chain, and the question asks you to confirm. **Partial** means the on-chain data leaves a gap. **Unknown** means we found nothing.

## Contracts and control

1. **Source code (Unknown).** Will you verify the source of the rToken implementation (`0x752C8073033046898aF127b3C78210E0D6e6C764`)? We would also want the beacon (`0x9a570740FaF9C77255e389a7BcCB7D460A5f4948`), the action registry (`0xd01f8AA971A3f4d13d52299bDD30225B1D7F40F1`), the minter (`0x129Ea4DDb91C836f89Dfa9EF8102F9E505DFC4ba`), the manager (`0x835b6725E6f017803d68a0AB78FDAaa6495C60Bc`) and the dividend claim contract (`0x0b751b1ddd20ec589c14a3186161c97267f8d3eb`). Is there a published audit?

2. **Upgrades (On-chain).** The beacon for all 3,334 rTokens is owned by a 3-of-5 Safe (`0x7fD7…4fdc`), with no timelock. It was upgraded on 2026-07-29, 08-27 and 10-17. Would you add a timelock or advance notice for upgrades? Who are the signers, and what is your key policy? One signer (`0x181f…ed90`) is also on the admin Safe; is that intended?

3. **Selectors without public signatures (Partial).** Please confirm what these do:
   - `0xe5839443`: we believe it executes a registry action, taking the id and the from/to ratio.
   - `0x79c36a7f`: we believe it sets the action registry.
   - `0x7b377df0`: we believe it returns the registry.
   - `0xf83c24a5`: it is used for name changes.

   Are there any other functions that change balances, the multiplier or `rebaseIndex`?

4. **Issuer powers (Partial).** In simulation we found:
   - **Freeze:** the admin Safe can freeze any account, which blocks transfers from and to it.
   - **Pause:** the operator EOA `0x6C5b…1f00` can pause all transfers; only the Safe can unpause.
   - **`emergencyWithdraw`:** moves only tokens held by the token contract itself.

   We found no way to burn or move a holder's balance. Is that complete? When would you freeze a lending protocol's escrow contract, and would you tell the protocol first? What does the sanctions-list contract (`0x1faf…88A7`) check?

## Corporate actions

5. **The 2026-10-17 migration (On-chain).** Your upgrade replaced the rebasing index with the ERC-8056 multiplier, and every holder's balance on 18 tokens changed by the split factor. Is the multiplier model now final? Would any future change to balances be announced in advance?

6. **Execution timing (On-chain).** Registry actions carry an effective time, but the token does not check it: in a fork test, the rSOXX split executed 5 hours early. What is your target delay between the effective time and execution? Could you enforce "not before" on-chain, or schedule through `newUIMultiplier`/`effectiveAt`, which are always equal to the current value today?

7. **Errors on record (On-chain).** Please explain these:
   - **rCRWD 4:1:** executed 2026-06-25, reversed 06-29, re-executed 07-02.
   - **rHON 2→1:** executed twice on 2026-06-29 (04:00 and 10:49 UTC) and carried into the migration as 0.25. xStocks' HONx is about 1.0 after its own change that day. Which is right?
   - **rMVLL and rNVDL:** executed two days after their effective date.

   How are such errors detected and corrected, and are holders compensated?

8. **Unexecuted actions (On-chain).** These rebases are past their effective time and still pending:
   - rMTUM 1→4 and rQUAL 1→4 (effective 2026-11-05 07:00 UTC; both have supply; rSOXX and rITA from the same batch were executed at 08:30). Neither xStocks nor Robinhood lists these funds, so we could not confirm the splits.
   - rMVIS 15→1 (effective 08-03)
   - rNGKSY 1→3 (10-02; token paused since 10-03)
   - rBUUU 1→10, twice (10-26 and 10-27)
   - rENLV 16→1 (10-27)
   - rPARA 10→1 (10-27)

   Do the tokens' multipliers match the shares held for them today? Why are these pending?

9. **Execution time (On-chain).** You executed rSOXX 3:1 at 08:30 UTC on 2026-11-05. xStocks activated SOXXx at 14:00 UTC and Robinhood at 14:30 UTC, the US open. How do you choose the execution time? Which price, pre- or post-split, do your own quotes and Bitget use between your execution and the open?

10. **Notice (Partial).** Rebases are usually created three days before they take effect, at 07:00 UTC. Is that a commitment? Is there an API or webhook as well as the registry events?

11. **Mergers, spin-offs and delistings (Unknown).** We have seen no merger or spin-off action type. rEA, rWBD, rRAMP and rINDV were delisted, and rEA (4.84) and rWBD (102.5) are still held. What do holders receive, and when? Would a payout reach a contract holder such as an escrow vault? How much notice do holders get before a delisting?

## Dividends

12. **Dividends in lending protocols (Partial, from your docs).** Your docs say dividends go to the depositor, traced by Merkl through supported protocols, and are held for unsupported ones. For a lending market built on Euler V2 on Arbitrum, where rTokens sit in an escrow vault and depositors hold vault shares through sub-accounts:
    - would Merkl's snapshot cover it, and what would you need from us?
    - how long are held dividends kept, and how are they released once support is added: back-paid for every past record date, to the depositor at each one?
    - is the dividend attributed to the owner of the Euler sub-account holding the vault shares (EOA, Safe or smart wallet)? How many layers of contracts does Merkl trace through?
    - for a contract Merkl can't trace through, do you hold the dividend, or pay the contract address? A lending vault can't move USDT0 sent to it.
    - if collateral is liquidated before the record date, is the new holder entitled, as we assume?
    - about 11% of funded USDT0 has been claimed so far. Is the rest held for unsupported protocols or not yet sent?

12a. **Large unpaid holders (On-chain).** `0xed9a…8771` holds rTokens in 245 dividend-paying names and has been paid in 2; `0x4cad…1f17` (47 names) and `0xadff…116d` (7) have never been paid. Are these Reality or Bitget inventory, excluded on purpose?

12b. **Stock dividends (Partial, from your docs).** Stock dividends are paid in rTokens. Are they sent like cash dividends (relayed, through the same claim contract), and is the per-token price left unchanged apart from the ex-date drop?

13. **Amounts (Unknown).** Are per-share amounts net of US withholding? For example, NEE 0.4345 and GOOGL 0.1535 look like 70% of gross. Does the rate depend on the holder?

## Liquidity and redemption

14. **Who can redeem (Partial).** The manager `0x835b…60Bc` redeems atomically for USDC. It requires a registered ID in `0x36e2…18d4`, which your admin Safe adds (7 IDs, 12 wallets so far), and a signed quote. Can a third party, such as a liquidator contract, be registered? What are the quote validity, size limits, fees, spread and hours? Does it work at weekends?

15. **Holders (On-chain).** In each major name, two or three EOAs hold 97–100% of supply (`0xadff…116d`, `0x4cad…1f17`, `0xed9a…8771`). Whose are they (Bitget custody, market makers, Reality inventory)? Are there plans for DEX liquidity beyond the four Uniswap v3 USDC pools (rAAPL, rCRCL, rHOOD, rSPCX)?

16. **Price feeds (Unknown).** Do you publish a price feed or an oracle for rTokens? Do you work with Chainlink, RedStone or Pyth?

## Legal

17. **Eligibility (Unknown).** rTokens are described as unregistered securities sold to eligible non-US persons. Do your terms allow rTokens to be used as collateral in permissionless lending protocols? Who is the legal issuer, and what claim does a holder have on the underlying shares at Alpaca?
