# Robinhood Stock Tokens

*Read on-chain 2026-11-04 on Robinhood Chain. Design docs cite these findings by ID (RH-1 to RH-11). Questions to Robinhood: POP-59. Verdict: good design; wait for Arbitrum; burn risk accepted as issuer risk.*

## Summary

Read on-chain on 2026-11-04 on Robinhood Chain (chain 4663, Arbitrum Nitro; block ~106.0M) and exercised in `eval/fork/RobinhoodChainFork.t.sol` and `eval/robinhood/`. Robinhood is expected to deploy on Arbitrum; these findings cover the token design. Evidence: RH-1 to RH-11.

**How the token works** (ERC-8056 "Scaled UI Amount"):

- `balanceOf` and `totalSupply` are raw and **never change**. Robinhood's docs: "Stock tokens are not rebasing tokens."
- `uiMultiplier()` (18 dp) is underlying shares per token. Splits, reverse splits and reinvested cash dividends change only the multiplier.
- `newUIMultiplier()` and `effectiveAt()` show a pending change; `UIMultiplierUpdated(old, new, effectiveAt)` is emitted when one is scheduled.
- `oraclePaused()` is Robinhood's advisory flag that a corporate action is being processed. It does not stop transfers.
- 18 decimals; accepted by the adapter.

**Pricing rule: the token is the oracle base.**

- The escrow holds the token itself. No wrapper.
- Configure a direct `token → USD → adapter` route.
- Collateral value does not move when the multiplier activates; only a keeper push moves it. A split is a 0% push when the keeper uses the new multiplier (fork test).
- Robinhood reverse splits need no `adminSetPrice`, unlike per-token prices that ignore the multiplier.

**Keeper rules [Policy]:**

- Price per token = equity price × `uiMultiplier()` in effect at the push block. Chainlink's Robinhood feeds (58 of 203 tokens) quote the same value and can be used as a cross-check. Robinhood's REST `/prices` is raw equity, not multiplier-adjusted.
- Do not push while `oraclePaused()` is set; let the name go stale.
- Apply a multiplier change only if `/corporate-actions` lists a matching action. Otherwise alert and stop pushing that name. On 2026-11-04 SOXX's multiplier was set to 3.0 for three hours and then reverted, with no published SOXX split. The real 3:1 split took effect on 11-05, so the error was the date (RH-6).
- Splits: don't push between the ex-date session open and `effectiveAt`. Robinhood's splits so far took effect at the US open (13:30 / 14:30 UTC).
- Reinvested dividends: the multiplier rises about 10 minutes after scheduling, mid-session. Accept the dip of about the dividend size until it does.

**Controls held by Robinhood.** One registry contract, `0xe10b6f6B275de231345c20D14Ab812db62151b00`, is the beacon (implementation) for every token, the role store, the blocklist and a global pause. Every role holder is an EOA except one Robinhood contract.

| Role | Holder | Power |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | EOA `0xd6F8…B66D` | Grant and revoke every role |
| `BEACON_UPGRADER_ROLE` | EOA `0xCd8C…E094` | Upgrade every token in one call |
| `MULTIPLIER_UPDATER_ROLE` | EOA `0x9290…8143` | Set any multiplier, instantly or at any future time |
| `ADMIN_BURNER_ROLE` | EOA `0x957B…74D4` | `adminBurn`: burn from any holder, no allowance |
| `BURNER_ROLE` | EOA `0x6E40…D8C1` (automated); contract `0x1364…9C08` | `burn`: burn from any holder, no allowance |
| `MINTER_ROLE` | EOA `0x2b94…3a87` (automated); contract `0x1364…9C08` | Mint |
| `PAUSER_ROLE` | EOA `0xe7BC…F22A` | Pause every token at once (registry) |
| `TOKEN_PAUSER_ROLE` | EOA `0xFCcF…Ab23` | Pause one token |
| `ORACLE_PAUSER_ROLE` | EOA `0x7369…4aBC` | Set or clear `oraclePaused` |
| `BLOCKER_ROLE` | EOA `0x913c…28fD` | Blocklist any address (247 so far) |

**Burns are issuer risk [Policy].** A Robinhood key can burn tokens straight out of a Poppie escrow. No contract can prevent this. It is accepted as issuer risk and bounded by per-issuer supply caps. If it happens:

- EVK tracks escrow cash internally, so the router keeps valuing the escrow at its pre-burn cash: collateral is overvalued, and the last depositors cannot withdraw (modelled in `test_RH_burnFromEscrow_ozSharesLoss_cashTrackingOvervalues`).
- Response: alert on any `Transfer` to `address(0)` from a Poppie escrow; pause the name in the oracle; cut its LTVs; treat the shortfall as bad debt for the reserve.

**What pauses do to Poppie** (fork tests):

- Token pause, registry pause or a blocklisted escrow: escrow deposits and withdrawals revert. Escrow shares still move, so EVK seizure should still succeed; the liquidator cannot withdraw until the pause ends.
- Oracle pause flag: transfers continue. The keeper stops pushing.

Open items: tracked in Linear, project Euler v2 (Poppie).

**Listing rule for Robinhood [Policy]:**

- list only addresses from Robinhood's `/assets` registry for the target chain, and check `ACCESS_CONTROLLED_REGISTRY()` and the beacon implementation;
- require ERC-165 support for `IScaledUIAmount` (`0xa60bf13d`) and `IScaledUIAmountNewUIMultiplier` (`0x4bd27648`);
- route the token directly; never wrap it;
- cap total Robinhood exposure as one issuer, since one registry and one set of keys cover every token.

**Reference addresses (Robinhood Chain):**

| | Address |
| --- | --- |
| AAPL token (beacon proxy) | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |
| SOXX token (beacon proxy) | `0x75742c18BC1f1C5c5f448f4C9D9C6F66dafAAa38` |
| Registry (beacon, roles, blocklist, global pause) | `0xe10b6f6B275de231345c20D14Ab812db62151b00` |
| Token implementation | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` |
| Chainlink AAPL/USD feed (proxy) | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |

Token addresses come from `https://api.robinhood.com/rhj/assets` (`deployments[].contractAddress` per `chainId`).

## Findings

Issued by Robinhood Assets (Jersey) Limited as tokenised debt securities. Read-only `cast` calls against `https://rpc.mainnet.chain.robinhood.com` (block ~106.0M), the public API at `https://api.robinhood.com/rhj/`, and the fork and mock suites. Robinhood is expected to deploy on Arbitrum later; liquidity and availability are out of scope here. Addresses are under "Reference addresses" above.

| ID | Status | Finding | Evidence |
| --- | --- | --- | --- |
| RH-1 | Not an issue | ERC-8056 "Scaled UI Amount". `balanceOf` and `totalSupply` are raw and never change; `uiMultiplier()` (18 dp) is shares per token; `newUIMultiplier()` and `effectiveAt()` expose a pending change; `balanceOfUI`/`totalSupplyUI` are views only. ERC-165 reports the core, pending-multiplier and balances interfaces, not the conversion one. 18 decimals. **No wrapper needed: the escrow holds the token, and the token is the oracle base** (direct `token/USD → adapter` route) | `test_fork_rh_tokenFacts`; `supportsInterface` |
| RH-2 | Not an issue | A scheduled 2:1 split on the real AAPL token leaves the escrow's raw balance and the router value unchanged at activation; the keeper's push (equity/2 × new multiplier) is a 0% move. On the mock, 4:1, 1:10 and any ratio from 0.01 to 100 behave the same. The PATH-2 problem cannot happen: there is no vault to resolve through. Real splits: CRWD 4:1 took effect 2026-07-02 13:30 UTC (the US open), so split-adjusted trading and the multiplier line up | `test_fork_rh_splitThroughRouterIsContinuous`, `test_RH_forwardSplitIsContinuous`, `test_RH_reverseSplitIsContinuous`, `testFuzz_RH_anyMultiplierIsContinuous`; `UIMultiplierUpdated` logs |
| RH-3 | Not an issue | Cash dividends are reinvested by raising the multiplier; nothing is sent to holders. All 36 entries in `/corporate-actions` are cash dividends (19 completed, 17 in progress). Increases are scheduled about 10 minutes ahead, mid-session (e.g. CCL 2026-08-31 15:10 UTC, SGOV monthly). Collateral value dips by the dividend at the ex-date push and recovers once the multiplier rises | `test_RH_reinvestedDividendDipsThenRecovers`; API; logs |
| RH-4 | Issue, needs Robinhood (POP-59) | `MULTIPLIER_UPDATER_ROLE` is one EOA, `0x9290…8143` (69 transactions). `updateMultiplier(uint256)` applies any value instantly; `updateMultiplier(uint256,uint256)` rejects only past times ("Effective time must not be in the past"). Simulated and forked: ×1000 instant, ×0.001 with 60 s notice. Observed notice: ~10 min (dividends) to 1.2–12.5 h (splits). Collateral value does not move on-chain when the multiplier changes; only a keeper push can move it | `test_fork_rh_multiplierUpdaterIsUnbounded`, `test_RH_rogueMultiplierDoesNotMoveValue`; `eth_call` |
| RH-5 | **Issuer risk** (accepted; managed with issuer caps) | Robinhood can burn tokens from any holder without an allowance: `adminBurn` (`ADMIN_BURNER_ROLE`, EOA `0x957B…74D4`) and `burn` (`BURNER_ROLE`, automated EOA `0x6E40…D8C1`, 79k transactions). A contract `0x1364…9C08` (UUPS proxy with `LIQUIDATOR_ROLE`, `closePosition`, `USDG`) also holds MINTER and BURNER. Backed's xStocks burner cannot do this (`BackedToken: Cannot burn account`). Effect on Poppie: with an OZ `ERC4626` the loss shows at once, pro rata. With EVK's internal cash accounting (modelled), the router keeps valuing the escrow at pre-burn cash, so collateral is overvalued, and the last depositors cannot withdraw | `test_fork_rh_issuerCanBurnFromEscrow`, `test_RH_burnFromEscrow_ozSharesLoss_cashTrackingOvervalues`; `eth_call` |
| RH-6 | Issue, keeper rule | SOXX's multiplier (a real 3:1 split, applied a day early) was set from 1.00045 to 3.0014, effective 2026-11-04 14:30 UTC (scheduled 13:16 UTC), and set back to 1.00045 effective 17:32 UTC (scheduled 16:55 UTC). Both were sent by the updater EOA. `/corporate-actions` lists no SOXX split, and Robinhood has no Chainlink SOXX feed. `oraclePaused()` was set 13:15–14:33 and again from 15:42 UTC; it was still set at 18:18 UTC. CRWD's 4:1 schedule was also sent twice (12.5 h and 1.2 h before activation, same values). The cause is unknown. Reality's registry has an iShares SOXX 1→3 split effective 2026-11-05 07:00 UTC (RE-5). Confirmed on 2026-11-05: Robinhood's SOXX multiplier is now 3.0014, effective 14:30 UTC, so the 2026-11-04 change was the correct split, applied exactly one day early, then reverted. xStocks (14:00 UTC) and Reality (08:30 UTC) applied it on 11-05. Under the direct route, Poppie collateral would be affected only if the keeper followed the change | `UIMultiplierUpdated` logs, `OraclePaused`/`OracleUnpaused` logs, API |
| RH-7 | Issue, keeper rule | `oraclePaused()` on the token is Robinhood's signal that a corporate action is being processed. It is advisory: transfers still work while it is set. Keeper rule: do not push while it is set; the name goes stale and resumes on the first in-breaker push, without admin | `test_fork_rh_oraclePauseIsAdvisory`, `test_RH_oraclePausedFlag_keeperSkipsThenResumes`; docs |
| RH-8 | Issue, workaround | One registry `0xe10b…1b00` serves every token as beacon (implementation `0xb354…5aE2`), role store, blocklist and global pause. All role holders are EOAs, including `DEFAULT_ADMIN_ROLE` (`0xd6F8…B66D`) and `BEACON_UPGRADER_ROLE` (`0xCd8C…E094`, which can upgrade every token in one call). A token pause (`TOKEN_PAUSER_ROLE`) or a blocklisted escrow freezes escrow deposits and withdrawals; escrow shares still move, so EVK seizure should still work, but the liquidator cannot withdraw. A registry pause (`PAUSER_ROLE`) freezes every token at once; used once, for 4 minutes on 2026-06-30. 247 addresses are blocklisted | `test_fork_rh_tokenPauseFreezesEscrowNotShares`, `test_fork_rh_registryPauseFreezesAllTokens`, `test_fork_rh_blockedEscrowCannotMoveTokens`, `test_RH_pauseAndBlockFreezeEscrowButNotShareSeizure`; registry logs |
| RH-9 | Issue, needs Robinhood (POP-59) | The API's corporate-action types include spin-off, cash, stock and mixed mergers, redemption, name change, worthless removal, rights distribution and unit split, all marked "not active at launch". How they pay out (cash, a second token, a burn and re-mint) is not documented. A payout sent to the escrow would be stuck (DIV-1) | `/corporate-actions` docs |
| RH-10 | Info | Chainlink publishes one feed per token (8 dp, heartbeat 86400 s, deviation 0.5%, 24/5) that already includes the multiplier. Only 58 feeds exist for 203 tokens, although Robinhood's docs say every token has one. The keeper can use a feed as a cross-check, not as the source. AAPL feed $354.42 vs implied equity $354.21 (multiplier 1.000566). The REST `/prices` endpoint is raw equity, not multiplier-adjusted | `test_fork_rh_chainlinkFeedIsPerToken`; Chainlink directory |
| RH-11 | Needs Robinhood (POP-59) | All 203 tokens are on chain 4663 only. Each deployment has `transporterEnabled` and `replicatorEnabled` flags (both false), suggesting a future Chainlink CCIP route. Unknown: whether Arbitrum tokens would be native or bridged, and whether the multiplier, `oraclePaused` and blocklist would stay in sync across chains. The 2025 "Classic" Stock Tokens on Arbitrum One are app-only derivatives and cannot be collateral | API; Robinhood docs |

Keeper inputs for Robinhood: the per-token price is equity × `uiMultiplier()`, using the multiplier in effect at the push block. `/corporate-actions` explains each multiplier change (for example `FORWARD_SPLIT` with `oldRate`/`newRate`). `/assets` gives `currentMultiplier` and `pendingMultiplier`.
