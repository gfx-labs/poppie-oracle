# xStocks (Backed) on Arbitrum

*Read on-chain 2026-11-02 to 11-12, with Backed's replies of 2026-11-03/04. Design docs cite these findings by ID (XS-1 to XS-14). Questions still open with Backed: `docs/issuerResearch/xStocks-Backed-Questions.md`. Verdict: listable, with caps sized to Backed's quoted depth per session.*

## Summary

Read on-chain on 2026-11-02 (block ~520.7M) and exercised in `eval/fork/XStocksArbFork.t.sol`.

**How the V2 wrapper works** (`WrappedBackedTokenImplementation` v1.0.0):

- One wrapper share is one token share unit. `convertToAssets(1e18)` equals the multiplier: AAPLx `1003269012539818700`, SPYx `1007474126658766000`.
- `totalAssets` is supply × multiplier, so donations do not move the rate.
- A split leaves wrapper shares unchanged and scales `convertToAssets` (fork test).
- Deposit and redeem keep at least 1:1 backing; rounding leaves dust in the wrapper (fork test).
- 18 decimals; accepted by the adapter.

**Controls held by Backed** (same on AAPLx and SPYx):

| Role | Holder | Power |
| --- | --- | --- |
| Token and wrapper `owner`, owner of both ProxyAdmins | Safe `0x4975…3a65`, 2-of-3 | Upgrade token and wrapper logic instantly (no timelock); set pauser, fees, multiplier updater, sanctions list |
| Token and wrapper `pauser` | Safe `0x8768…FC50`, 3-of-5 | Pause all transfers of the token or the wrapper |
| Token `multiplierUpdater` and `burner` | **EOA** `0x5F7A…a2aD` | Set any multiplier at any activation time (see below). Also holds >99% of supply, owns `AtomicSwap`, signs for the pauser Safe |
| Token `minter` | EOA `0x0A93…4C2a` | Mint |
| Sanctions list | Chainalysis oracle `0x40C5…C8fb` | Blocks sanctioned senders, receivers and spenders on both token and wrapper |

**Multiplier updater:** an automated hot EOA. The contract bounds neither size nor notice: simulated updates of ×1000, ×0.001 and past activation times all succeed (XS-9). Observed notice: AAPLx 18 minutes to about 4 hours; HONx 4–6 minutes (XS-9).

- **Backed's notice:** normally about 2 hours; as little as 15 minutes when its data providers deliver late. No on-chain minimum delay was offered.
- **Schedule feed:** `GET https://api.xstocks.fi/api/v2/public/assets/{symbol}/multiplier?network=Arbitrum` returns `currentMultiplier`, `newMultiplier`, `activationDateTime` and `reason` (`FeeAccrual`, `Dividend`, `Split`, `ReverseSplit`, `Administrative`). Values are floats, so price from the on-chain multiplier and use the API for the reason.
- **Events are lazy:** `MultiplierUpdated` is emitted on the first interaction after activation, not at activation (XS-14). Read `newMultiplierActivationTime` and `getCurrentMultiplier()` on Arbitrum.
- **Past error:** on 2026-06-29 HONx's multiplier was halved for 8 h 25 min, with about 5 minutes' notice, then reset 2.44% below its prior value (XS-13, `docs/issuerResearch/HONx-Multiplier-Incident.md`). A keeper that followed it would have pushed −50%. This is why the keeper applies only multiplier changes that match a known corporate action.

Management fee: `feePerPeriod = 0`, `periodLength = 1 week`, so there is currently no fee decay. Backed's owner can turn it on.

**What pauses do to Poppie** (fork tests):

- Wrapper paused: no wrapper share can move, so escrow deposits and withdrawals revert. Prices are unaffected.
- Liquidation seizures move escrow shares, not wrapper shares, so they should still succeed during the pause (EVK seizes through the escrow's `transfer`; to confirm in the EVK harness). The liquidator cannot withdraw and sell until the pause ends.
- Token paused: wrapper shares still move, so escrow operations work; only unwrapping fails.

**Usage on Arbitrum.** The tokens exist, but nearly all supply is Backed inventory in the EOA above:

| Name | Arbitrum supply | Outside Backed's EOA | V2 wrapper supply |
| --- | --- | --- | --- |
| AAPLx | 72,045 | ~4 | 0 |
| SPYx | 29,101 | ~1.3 | 0 |
| TSLAx | 48,649 | ~2.1 | 0 |
| NVDAx | 108,045 | ~9.9 | 0.17 |
| QQQx | 32,883 | ~314 | 0 |
| MSFTx | 25,022 | ~1.3 | 0 |
| GOOGLx | 62,030 | ~606 | 0 |

There are no Uniswap v3 pools against USDC for AAPLx or SPYx, and 31 AAPLx transfers moved 0.7 tokens in the 80 hours checked. The wrappers are deployed but unused.

**Exit for liquidators.** The only liquidity is Backed's own inventory, sold through Backed's RFQ contract `AtomicSwap` (`0x6F86Ba14De57e61630f49f1136A5C608269d8852`). Each trade needs a quote signed by Backed, valid for about 60 seconds. The contract checks that both sides of the trade (the address paying and the address receiving) are on Backed's allowlist; it does not check who submits the transaction. Evidence: XS-7.

The allowlist has 354 addresses: 342 EOAs and 12 contracts. One of the contracts is **Enso's shared executor** (`EnsoShortcuts`, `0x4Fe93ebC4Ce6Ae4f81601cC7Ce7139023919E003`), allowlisted since 2026-05-21. So Enso is already an onboarded party, and anyone using Enso's API reaches Backed's inventory without onboarding themselves.

| Counterparty on `AtomicSwap` (since 2026-05) | Swaps | Sells (liquidation direction) | Largest sell | Reached through |
| --- | --- | --- | --- | --- |
| **Enso** (`EnsoShortcuts`) | 125 | 41, $62k | $38k | Enso's router; 0x's API (which sources xStocks from Enso); Oku's router; ERC-4337 smart wallets; 47 different senders |
| Market maker or solver contract `0x083b…af53` | 90 | 49, $62k | $13k | CoW settlement and another intent settlement |
| Market maker or solver contract `0x0000…7628` | 82 | 26, $18k | $14k | CoW settlement and its own contract |
| Other | 2 | 0 | — | Direct |
| **Total** | 299 | 116, $142k | $38k | |

Buys: 183 swaps, $1.11M, largest $434k. All 27 names fill on weekdays in every session, including overnight (Enso: 10 of its 41 sells were overnight); **no fill on any weekend**. Only the token trades, so liquidators must unwrap first.

**What Backed quotes** (Backed, 2026-11-04):

| Session | Executable sell size per trade | Slippage, one way (NVDAx) |
| --- | --- | --- |
| Market hours, majors | Up to $1M | ~5 bps |
| Extended hours | Not stated | ~10 bps |
| Overnight, long-tail names | Down to $10k | ~20 bps |
| Weekends | **None** | — |

Poppie's own $1k NVDA test agrees: 6–7 bps round trip in market hours, about 40 bps overnight. Slippage is small next to liquidation discounts. The binding limits are quote size, settlement and weekends.

**Who liquidates.** Backed will not liquidate or act as a backstop buyer, and Poppie will not onboard with Backed or any other issuer (legal exposure). Poppie will not run its own liquidator at launch (D9). Liquidations are left to third parties, who can reach Backed's inventory without onboarding:

- **Through Enso or 0x (atomic):** Enso's executor is allowlisted, so any liquidator can liquidate, unwrap and sell through Enso's API in one transaction. 0x reaches the same route.
- **Through CoW (asynchronous):** solvers fill from Backed through their own allowlisted contracts. The liquidator needs its own USDC and carries price risk until the fill.

None of these is committed. The liquidity is Backed's inventory on Backed's terms (quote size, hours, no weekends), and Backed can remove Enso from its allowlist without notice. So the design treats thin exit liquidity as a risk to be capped, not solved: see "Thin liquidity and liquidations" in `docs/zeroContracts/Design.md`.

**Liquidation rules [Policy]:**

- Assume no exit at weekends; discounts cover holding until Monday.
- Size each name's supply cap to Backed's quoted size in the **weakest session in which the keeper prices it**, since liquidations can happen in any priced session. Alternatively, stop pricing a long-tail name in sessions without enough depth, so it goes stale instead.
- Rely on third-party liquidators; size caps and discounts so that liquidating is worth their while (see "Thin liquidity and liquidations" in `docs/zeroContracts/Design.md`).

**Reference addresses (Arbitrum; identical on other EVM chains):**

| | AAPLx | SPYx |
| --- | --- | --- |
| Token (proxy) | `0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a` | `0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48` |
| V2 wrapper (proxy), use this | `0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f` | `0xe7e553cd128f0011777323a0b44a7b96ea1cb540` |
| Legacy wrapper, never use | `0x5AA7649fdbDa47De64A07aC81D64B682AF9C0724` | `0xc88fcd8b874fdb3256e8b55b3decb8c24eab4c02` |

| Shared contract | Address |
| --- | --- |
| Wrapper implementation (`WrappedBackedTokenImplementation`) | `0x76C6851ea0B2741EeDcBBED240715E8817E85583` |
| Wrapper ProxyAdmin | `0x312063009E74142339Edc92BcfF6CfCfAA958BFA` |
| Token implementation (`BackedAutoFeeTokenImplementation`) | `0x65c40D624Af3B18C109fBF87B7DEff34CdC5f19b` |
| Token ProxyAdmin | `0x696c685a02a1fc6e2aacbe26cd6695f4f4a6a085` |

The implementation can be read from the proxy's EIP-1967 slot or from the ProxyAdmin's `getProxyImplementation`; both agree. Wrapper addresses come from `https://api.xstocks.fi/api/v2/public/assets/<SYMBOL>`, field `wrapperAddressV2`.

**Listing rule for xStocks [Policy]:**

- hold only `wrapperAddressV2`, and check its implementation through the ProxyAdmin;
- reject the legacy `wrapperAddress`;
- require an exit route open to third-party liquidators before listing any name: Backed's quoted size for that name per session, reachable through Enso, 0x or CoW, or DEX depth;
- size the name's supply cap to that exit depth (see "Thin liquidity and liquidations" in `docs/zeroContracts/Design.md`).

## Findings

Read-only `cast` calls against public Arbitrum RPCs, plus the fork suite. Addresses are under "Reference addresses" above.

| ID | Status | Finding | Evidence |
| --- | --- | --- | --- |
| XS-1 | Not an issue | The V2 wrapper (`WrappedBackedTokenImplementation` v1.0.0, implementation `0x76C6…5583`) maps one wrapper share to one token share unit: `convertToAssets(1e18) == getCurrentMultiplier()` (AAPLx `1003269012539818700`, SPYx `1007474126658766000`). `totalAssets` is supply × multiplier, so donations cannot move it. Deposit mints exactly the share units received; redeem keeps backing ≥ supply | `test_fork_wrapperFacts`, `test_fork_depositRedeemKeepsOneToOneBacking`; ProxyAdmin `getProxyImplementation` |
| XS-2 | Not an issue | A Backed-scheduled 2:1 split leaves wrapper shares unchanged, doubles `convertToAssets`, does not move the router value at activation, and the keeper's per-share push is a 0% move | `test_fork_splitThroughRouterIsContinuous` |
| XS-3 | Issue, workaround | Wrapper pause stops all wrapper share transfers, so escrow deposit and withdraw revert. Token pause only blocks unwrapping. The test used a mock escrow: in EVK, liquidation seizes escrow shares via `transfer` (`Liquidation.sol` `enforceCollateralTransfer`), which does not move the wrapper, so seizure likely still succeeds (see PAUSE-1) | `test_fork_wrapperPauseFreezesEscrowMovement`, `test_fork_tokenPauseBlocksUnwrapOnly` |
| XS-4 | Issue, accepted | `multiplierUpdater` (and `burner`) is a single EOA, `0x5F7A…a2aD`, which can set any multiplier. Owner of token, wrapper and both ProxyAdmins is a 2-of-3 Safe with no timelock; pauser is a 3-of-5 Safe that includes the same EOA. Confirmed role: `multiplierUpdater()` returns it, `NewMultiplierUpdater` emitted at deployment. Plain EOA, 19,622 Arbitrum and 38,073 Ethereum transactions (automated hot key). Backed (2026-11-03): values come from "verified data sources". Handled by the keeper rule in XS-9 | `cast call`, `cast logs`; Backed reply |
| XS-5 | **Likely blocker for listing** | Over 99% of Arbitrum supply of AAPLx, SPYx, TSLAx, NVDAx, MSFTx (and ~98–99% of QQQx, GOOGLx) sits in the Backed EOA; V2 wrappers hold 0 (NVDAx 0.17); no Uniswap v3 USDC pools for AAPLx or SPYx; 31 AAPLx transfers moved 0.7 tokens in 80 hours. Ethereum looks similar for AAPLx (72,457 of 74,145 in the same EOA). No DEX exit. All observed liquidity is Backed's inventory through `AtomicSwap`. Backed's stated quote sizes (XS-7) now set the exit limit, not on-chain history | `cast call`, `cast logs` |
| XS-6 | Not an issue now | `feePerPeriod = 0`, `periodLength = 604800`: no management-fee decay today. Activation times vary (SPYx: 2026-10-30 23:55 and 2026-10-31 13:45 UTC; AAPLx: 2026-08-08 00:30 UTC), and the Arbitrum multiplier matches Backed's API | `multiplierUpdates`, xStocks API |
| XS-7 | **Exit confirmed with limits; reachable by third parties through Enso (D9)** | Backed's `AtomicSwap` `0x6F86…8852` (RFQ: Backed-signed quotes valid about 60 s; upgradeable (`AtomicSwapUpgradeable`, verified), pausable, owner and counterparty EOA `0x5F7A…`). `executeSwap` checks the allowlist on the four transfer endpoints (who pays and who receives on each side), **not on the caller**. The allowlist has 354 addresses (342 EOAs, 12 contracts, none removed). One contract is **Enso's shared executor `EnsoShortcuts` `0x4Fe9…E003`**, added 2026-05-21. Fills to 2026-11-05: 299 swaps in 27 names. Taker sells (the liquidation direction): 116, $142k, largest $38k. Buys: 183, $1.11M, largest $434k. By counterparty: Enso 125 swaps (41 sells, $62k, the $38k largest), reached through Enso's router, 0x's AllowanceHolder/Settler, Oku's router, ERC-4337 smart wallets and other contracts (47 senders); two solver or market-maker contracts (`0x083b…af53`, 90; `0x0000…7628`, 82) fill CoW and another intent settlement. Weekday fills in all sessions, including overnight; **none at weekends**. Wrappers never traded. **Backed (2026-11-04):** no backstop buyer; up to $1M per trade on majors in market hours, $10k on long-tail names overnight, **none at weekends**; allowlisting a contract needs an onboarded party. **Poppie (2026-11-05):** will not onboard with any issuer and runs no liquidator at launch; third parties liquidate through Enso, 0x or CoW (D9) | `AddressAllowed` and `SwapExecuted` logs; verified source; `eth_getCode`; traces (Tenderly); Enso deployment docs; Backed replies |
| XS-8 | Issue, policy (see XS-11, XS-12) | Mergers, spin-offs, delistings and migrations are handled case by case ("users are made whole"), with notice depending on when Backed learns. **Backed (2026-11-04): wrapper holders are not paid in the wrapper. Users must unwrap, and Backed provides a way to sell the token (Atomic RFQ through protocols, or other ways).** So nothing arrives at the wrapper or the escrow. Poppie's positions must be closed or liquidated, and the wrapper redeemed, before the event. Still unknown: the deadline, the notice, and what happens to wrapper shares left outstanding | Backed replies |
| XS-9 | Issue, keeper rule | No on-chain bound on multiplier updates: simulated calls from the updater succeed for ×1000, ×0.001, activation in 60 s or in the past; only a stale "current multiplier" argument or another caller reverts. Observed notice, from `updateMultiplierValue` calldata: AAPLx 18 min to ~4 h; HONx 4–6 min (2026-02-27, 2026-06-29) to ~4 h. Before the 2026 upgrade, updates applied instantly. **Backed (2026-11-04):** pending changes are published at `GET https://api.xstocks.fi/api/v2/public/assets/{symbol}/multiplier?network=Arbitrum` (`currentMultiplier`, `newMultiplier`, `activationDateTime`, `reason`: `FeeAccrual`, `Dividend`, `Split`, `ReverseSplit`, `Administrative`). Lead time is normally about 2 hours, but can be as little as 15 minutes when data providers deliver late. No on-chain minimum delay was offered. The API returns floats (AAPLx `1.0032690125398187` vs on-chain `1003269012539818700`), so the keeper prices from the on-chain value and uses the API for the reason | `eth_call` simulation; `MultiplierUpdated`, `MultiplierScheduled` logs; API call 2026-11-04; Backed reply |
| XS-10 | Info | Slippage by session (Backed, 2026-11-04): NVDAx about 5, 10 and 20 bps one way in the regular, extended and overnight sessions, depending on protocol and solver; spreads are being lowered gradually. Poppie's measurement for a $1k NVDA trade: 6–7 bps round trip in market hours, about 40 bps round trip overnight, consistent with Backed's figures. This is small next to liquidation discounts (8–20%). The binding limits are quote size, asynchronous settlement via CoW, and no weekend quotes | Backed reply; Poppie liquidity tool |
| XS-11 | Not an issue (one confirmed case) | **Spin-offs have been paid through the multiplier, not as a second token.** Comcast's Versant spin-off (1 VSNT per 25 CMCSA, distributed 2026-01-01): CMCSAx's multiplier rose 4.72% (1.01384 → 1.06167) on 2026-01-07 23:55 UTC, on Ethereum and Arbitrum. VSNTx was only listed eight months later (created 2026-09-01) and minted only to Backed's EOA. That is consistent with Backed selling the spin-off shares and reinvesting, probably together with the January dividend. The V2 wrapper follows the multiplier, so wrapper holders, escrows included, would have been credited with no action. Honeywell's Solstice spin-off (1 SOLS per 4 HON, 2025-10-30): HONx's multiplier rose 1.10% on 2025-10-30 21:22 UTC, the distribution date. That step is smaller than we would expect from the spin-off value, so it is unconfirmed (question 14). SOLSx was listed 2026-06-30 and minted only to Backed | `MultiplierUpdated` logs (Blockscout Ethereum; `eth_getLogs` Arbitrum); `NewToken` logs on Backed's token factory; token holder lists |
| XS-12 | Needs Backed | **No merger, delisting or token migration with outside holders has completed on EVM chains.** Backed's token factory on Ethereum (`0x9768…76F3`) has deployed 1,559 tokens. Of these, 43 are absent from the public API. Every one with supply is held entirely by Backed's EOA (plus dust in Backed's ops address `0xE531…`), is unpaused, and shows no burns. Examples: EAx, CBOEx, WBSx, EQRx, AVBx, HEI.Ax, and three tokens re-deployed within a week (TEFx, ACS.ESx, HNR1x). Old contracts stay live when Backed drops a token; nothing is burned or converted. **Pending cases:** KVUEx (Kenvue, being acquired by Kimberly-Clark for cash plus KMB shares) is now `allowedOperations: ["Redemption"]` and trading-halted in the API, while on-chain it is unpaused with a normal multiplier; KMBx was listed the same day as KVUEx. QRVOx (Qorvo, being acquired by Skyworks) is trading-halted, and SWKSx was listed on 2026-10-28. WBDx has lost `Issuance`. All their V2 wrappers have zero supply, so no wrapper holder has been through an event yet. **Signal:** losing `Issuance` or gaining `isTradingHalted` in the API came before these events and can trigger Poppie's wind-down | API (`allowedOperations`, `isTradingHalted`) 2026-11-04; factory and token logs; `totalSupply`, `isPaused`, wrapper `totalSupply` on Arbitrum and Ethereum |
| XS-13 | **Issue, keeper rule** | **HONx's multiplier was halved for 8 h 25 min** (`docs/issuerResearch/HONx-Multiplier-Incident.md`). On both chains, the updater scheduled 1.02409 → 0.51205 (exactly half) at 2026-06-29 15:24 UTC, active 15:30. It then scheduled a reset to 0.99907 (2.44% below the pre-halving value) at 23:50, active 23:55. Notice was about 5 minutes each time. Only 23.7 shares (0.05%) were outside Backed on Ethereum and none on Arbitrum, and nothing moved while halved. A keeper that followed it would have pushed −50%, which a 5000 bps breaker allows. The rule "apply only multiplier changes that match a known corporate action" rejects it | `updateMultiplierValue` calldata, both chains |
| XS-14 | Info | **`MultiplierUpdated` is emitted lazily**, on the first token interaction after activation, so log timestamps are not activation times (HONx's reset shows on 2026-07-09 on Ethereum and 2026-07-26 on Arbitrum, but took effect 2026-06-29 23:55). Schedules checked on HONx and CMCSAx were sent to both chains at the same time with the same activation time, so no cross-chain lag is evident. The keeper reads `newMultiplierActivationTime` and `getCurrentMultiplier()` on Arbitrum, not events | `updateMultiplierValue` transactions (Blockscout Ethereum, Arbitrum RPC) |

The xStocks docs' wrapper example (10 tokens at multiplier 1.1 mint 11 wrapped tokens) does not match the code, which mints 10. The code is authoritative.
