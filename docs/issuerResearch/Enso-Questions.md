# Questions for Enso (xStocks exit liquidity on Arbitrum)

*Nov 5, 2026. Not yet sent. Poppie plans to lend USDC on Euler V2 on Arbitrum against xStocks, held through Backed's V2 wrapper. Poppie will not onboard with Backed or any issuer directly, and will not run its own liquidator at launch. Liquidations are left to third parties, and we size each name's exposure to the exit they can reach. We want to confirm that any liquidator can sell seized xStocks for USDC through Enso, and how much, when (decision D9). A Poppie-run liquidator through Enso is deferred; questions 1–3 and 6 matter mainly if we build one.*

## What we see on-chain

- **Backed's quote contract:** every on-chain xStocks trade on Arbitrum settles through Backed's `AtomicSwap` (`0x6F86Ba14De57e61630f49f1136A5C608269d8852`). Each trade needs a quote signed by Backed, valid for about 60 seconds. Both counterparties must be on Backed's allowlist; the caller need not be.
- **Enso is allowlisted:** your executor `EnsoShortcuts` (`0x4Fe93ebC4Ce6Ae4f81601cC7Ce7139023919E003`) has been on that allowlist since 2026-05-21. It is the largest counterparty by count: 125 of 299 swaps.
- **Sells through Enso:** 41, totalling $62k; the largest was $38k. They came from Enso's router, 0x's AllowanceHolder, Oku's router, ERC-4337 smart wallets and other contracts, from 47 senders.
- **Hours:** fills land on weekdays in every session, including overnight. None landed at a weekend.
- **Quote lifetime:** in Enso's route calldata, the embedded Backed quote expires about 70 seconds after issue (Backed describes quotes as valid about 60 seconds; XS-7), and transactions land about 15 seconds after issue.

## Questions

1. **Access and terms.**
   - Which plan and licence does a liquidator need to sell xStocks through your API?
   - If we later run our own liquidator, does the API licence (end-user agreements, usage restrictions) fit a contract run by Poppie's own bot?
   - Are there fees for xStocks routes?

2. **Eligibility.** Your materials say xStocks are for "eligible users", under the issuer's rules.
   - What checks apply to an API customer, and to the address that receives the USDC?
   - Does Poppie need to pass anything to Backed through you, such as KYB or jurisdiction information? Our aim is not to onboard with Backed directly.
   - Can a contract (not an EOA) be the `fromAddress` and `receiver` for a sell?

3. **Contract callers.**
   - We would call your router from our own contract, with calldata your API built for our contract's address and an exact amount. Is that supported for xStocks → USDC on Arbitrum?
   - Is the `router` strategy the right one? The swap is one step inside a larger transaction: an EVC batch with deferred checks, where our contract holds the tokens.

4. **Size and limits.**
   - Do Backed's quoted sizes reach your API users in full? Backed told us up to $1M per trade on majors in market hours, and down to $10k on long-tail names overnight.
   - Do you add your own minimum or maximum order sizes, or rate limits per API key?
   - Can several sells in the same name go through in one block or one minute, as in a liquidation cascade?

5. **Hours.**
   - When do xStocks routes stop on Friday and resume on Sunday or Monday (UTC)?
   - What does the API return when Backed won't quote: an error, or a route through other liquidity?

6. **Quote lifetime and failures.**
   - How long is a route valid, and can we ask for a shorter or longer validity?
   - What happens if Backed's quote expires or is cancelled before our transaction lands? We expect a revert and a retry.
   - Is there a way to get a firm quote just before submitting?

7. **Wrapper.**
   - Can your API route Backed's V2 wrapper shares (`wrapperAddressV2`) to USDC directly, unwrapping as part of the route?
   - Or should our contract unwrap first and route the token?

8. **Reliability and continuity.**
   - What uptime do you target for the route API?
   - Would you notify integrators if Backed removed `EnsoShortcuts` from its allowlist, or if xStocks routes were paused?
   - Is the executor address stable, or could a redeployment move it off the allowlist?

9. **Other issuers.**
   - Do you route Reality rTokens on Arbitrum (Uniswap pools, or Reality's own redemption manager)?
   - Do you route Dinari dShares?
   - Do you route Robinhood Stock Tokens on Robinhood Chain, and on Arbitrum once they launch there?
   - Are you registered with Reality's redemption manager (`0x835b6725E6f017803d68a0AB78FDAaa6495C60Bc`)?

10. **Other providers.** Besides Enso, 0x's API routes xStocks through your executor, and two other contracts (`0x083b7197C834e6765D157360dEdE0F9b8912aF53`, `0x00000000001CE5eEDdd62382046b86B01d957628`) fill CoW orders from Backed. Do you know of other routes we should treat as independent fallbacks?
