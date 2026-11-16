# Peripheral contracts: specifications

*Nov 16, 2026. Contract specifications for the peripheral-contract design. The plan, with the risk register, levers and governance, is `docs/peripheralContracts/Poppie-Arbitrum-Peripheral-Plan.md`; the comparison with the zero-contract design is `docs/Design-Comparison.md`; metrics are in `docs/Risk-Metrics.md`. Gap IDs (G1–G12) are defined in the comparison.*

## Scope

- **Unchanged:** the audited v1 `PoppieEulerOracle` and `PoppieEulerAdapter`, and every stock Euler, Safe and OpenZeppelin contract. Nothing is forked or modified.
- **Added:** a few small Poppie contracts that plug into slots those contracts already expose.
- **Written from scratch.** Nothing is reused from the `scale` branch, which was a ground-up rebuild.
- **Everything in the zero-contract design still applies** (keeper, issuers, liquidity policy, Euler's emergency governor and cap steward). Contracts are added only where they remove a risk that policy can't.

## Where a contract can plug in

| Plug-in point | How it works | Verified |
| --- | --- | --- |
| **EVK vault hook** | Each vault has one `hookTarget` and a bitmask of hooked operations (`OP_DEPOSIT` … `OP_VAULT_STATUS_CHECK`). Before a hooked operation, EVK calls the target with the original calldata plus the authenticated caller (20 bytes) appended. If the target reverts, the operation reverts. Operations not in the mask never call it | EVK `422bf24`, `Base.sol` `invokeHookTarget`, `Constants.sol` |
| **Vault status check hook** | `OP_VAULT_STATUS_CHECK` runs at the end of every EVC batch that touched the vault, after all operations. A hook here sees the batch's final state | Same |
| **Vault views from a hook** | During a hooked operation the vault is locked against reentry, but the hook target is exempt for view functions (`nonReentrantView`). So a hook can read `totalBorrows`, `cash` and caps | `Base.sol:61-75` |
| **Oracle `admin` and `keeper` slots** | Each slot holds one address, which can be a contract. That contract then has every power of the slot | `PoppieEulerOracle.sol` |
| **Router `governor`** | One address; can be a contract | `EulerRouter` |
| **EVC batch** | A user batch can include calls to any contract; checks run once, at the end | EVC |

**One hook target per vault.** All hub logic must live in one contract, and all escrow logic in one. P1 therefore replaces Euler's `HookTargetGuardian`, an option in the zero-contract design.

## Rules every contract must follow

1. **Never block repay or liquidation.** `OP_REPAY`, `OP_REPAY_WITH_SHARES` and `OP_LIQUIDATE` are never hooked. A status-check hook passes when no borrow happened in the batch. On escrows, `OP_TRANSFER` passes while `evc.isControlCollateralInProgress()` (liquidation seizure).
2. **No custody.** No contract holds user funds or can move them.
3. **No upgrades.** Immutable code; parameters only through roles.
4. **`MS_OPS` can always remove a hook** (`setHookConfig`). A buggy hook is fixed by uninstalling it, at the cost of losing its protection. Slot holders (P3, P4, P6) have a timelocked exit back to a Safe.
5. **Bounded roles:** hot keys can only tighten.

## Contracts

### P1. Hub guard (hook on every hub)

Hooked operations: `OP_BORROW`, `OP_FLASHLOAN`, `OP_DEPOSIT`, `OP_VAULT_STATUS_CHECK`.

| Feature | Behaviour | Closes |
| --- | --- | --- |
| **Borrow rate limit** | On `OP_BORROW`, records the hub's `totalBorrows` before the batch's first borrow (transient storage). On the status check, if a borrow happened, requires net new borrows in the current window ≤ the hub's limit (for example $X per hour). Batches with no borrow always pass | G1 |
| **Guardian pause** | A guardian key can pause borrows and flash loans for a set time, renewable by the guardian. `MS_OPS` can unpause | G2 |
| **Sanctions screening** | On `OP_BORROW`: the account's EVC owner and the `receiver` must not be on Chainalysis's list or Poppie's denylist. On `OP_DEPOSIT` (lenders): the same for the depositor | G7 |
| **Origination fee** | Each batch with a borrow must also borrow `fee = amount × rate` to the hub's fee receiver. On `OP_BORROW`, the hook adds to "owed" or "paid" in transient storage, by receiver. The status check requires paid ≥ owed. Borrows of `type(uint256).max` ("all cash") are rejected | G9 |
| **Flash-loan policy** | Off, on, or paused; a fee needs the same pattern as the origination fee | G10 |
| **Account debt cap** (optional) | Debt per EVC owner ≤ a set amount | G11 |

State: per hub, the window start, the borrows at window start, the limit, the fee rate, the pause expiry. Transient: per batch, the borrows before, owed and paid.

### P2. Escrow guard (hook on every escrow)

Hooked operations: `OP_DEPOSIT`, `OP_MINT`, `OP_WITHDRAW`, `OP_REDEEM`, `OP_TRANSFER` (as needed).

| Feature | Behaviour | Closes |
| --- | --- | --- |
| **Scheduled pause windows** | Deposits and withdrawals revert during the issuer's published windows (for example Backed's multiplier activations), set by a scheduler key that can only add windows of bounded length. Transfers during liquidation always pass | G8 |
| **Sanctions screening** | On deposit: the account's EVC owner is screened. Mostly redundant for xStocks, whose token already screens | G7 |
| **Account freeze** (optional, legal decision) | Withdrawals blocked for an account on Poppie's denylist, for example under a court order. Liquidation still passes | G7 |
| **Guardian deposit pause** | Like P1, for collateral inflows | G1, G2 |

### P3. Oracle admin guard (in the oracle `admin` slot)

The Oracle Safe calls the guard, which calls the oracle.

| Call | Instant | Delayed |
| --- | --- | --- |
| `pauseAssets` | Yes, also by a guardian key | — |
| `adminSetPrice` | If within ±X% of the last price (or of the last price before a pause, which the guard records) | Otherwise; or instant with a second Safe's approval |
| `setAssetThresholds`, `setMaxPriceAge`, `setAssetMaxPriceAge` | If tightening | If loosening (including staleness disabled) |
| `setAnchorWindow`, `configureAssets` | `configureAssets` (it moves no price) | `setAnchorWindow` |
| `setKeeper` | To a pre-registered backup keeper | Any other address |
| `transferAdmin` | — | Long delay |

The guardian (or a second Safe) can cancel any queued call. Closes **G3**, Poppie's largest unbounded risk. Cost: gaps beyond the breaker wait for the delay or the second approval.

### P4. Keeper forwarder (in the oracle `keeper` slot)

- Several keeper keys may push; each runs its own process, so there's no shared-nonce coordination.
- `pauseAssets` by keepers is limited to N assets per day. Today a stolen keeper key can pause every asset and wipe every price.
- A guardian revokes a key instantly; the Oracle Safe (through P3) adds keys.

Closes **G4**. It is cheaper and tighter than the zero-contract Safe-plus-Roles keeper.

### P5. Add-only router governor (in the router `governor` slot)

- `MS_OPS` adds routes instantly, only to the Poppie adapter, and only for configured oracle bases.
- Overwrites, deletions and any other router change go through a timelock.

Closes **G6** without delaying listings, unlike the zero-contract timelock.

### Not needed as contracts

- **Emergency tightening and bounded cap changes:** Euler's `GovernorAccessControlEmergency` and `CapRiskSteward`, used in both designs (G5, G12).
- **Liquidator:** still deferred (D9). It would add no buyers.
- **Dividend capture:** still deferred (DIV-1).

## Suggested order

1. **P3 oracle admin guard.** The only bound on a compromised Oracle Safe.
2. **P1 hub guard,** with the rate limit, guardian pause and sanctions first; the fee can be switched on later.
3. **P4 keeper forwarder.**
4. **P5 router governor** and **P2 escrow guard.**

Each is independent; Poppie can adopt any subset and keep the rest of the zero-contract design.

## Open decisions

1. Which contracts, if any (audit budget)?
2. Rate-limit size per hub, and the window.
3. Oracle admin: delay length, the ±X% instant band, or a second Safe.
4. Keeper pause budget N.
5. Sanctions: screening only, or also the freeze (legal).
6. Origination fee rates per hub, or off at launch.
