# Poppie Euler Oracle

Custom oracle contracts for the Poppie x Euler V2 lending market (tokenized
US equities as collateral, USDT borrowable).

## Deployments

| Network | Contract | Address |
|---------|----------|---------|
| BSC (dev) | `PoppieEulerOracle` | [`0x0735787c7eA8d8B60Ae87cC27c724484E4488043`](https://bscscan.com/address/0x0735787c7eA8d8B60Ae87cC27c724484E4488043) |
| BSC (dev) | `PoppieEulerAdapter` | [`0x3aBEe5638d93d792c9b282f0204e925f9A50C09C`](https://bscscan.com/address/0x3aBEe5638d93d792c9b282f0204e925f9A50C09C) |

Dev deployment parameters:
- `maxPriceAge`: 3600s (1 hour)
- `anchorWindow`: 86400s (24 hours)
- `unitOfAccount`: `address(840)` (USD), 18 decimals
- 25 Ondo GM tokens configured (matching BSC production asset set)
- Admin: `0xDDeFb8145fA286195f091E3D7749e22B53Bb28bF`
- Keeper: `0x9e77D62f664cb1ebe40C0629841e69Dbf7f646e1` (GCP KMS)

Both contracts verified on BSCScan and Sourcify.

## Contracts

| Contract | File | Purpose |
|---|---|---|
| `PoppieEulerOracle` | `src/PoppieEulerOracle.sol` | Master price store |
| `PoppieEulerAdapter` | `src/PoppieEulerAdapter.sol` | Euler IPriceOracle (ERC-7726) adapter |
| `IPoppieEulerOracle` | `src/interfaces/IPoppieEulerOracle.sol` | Oracle interface |
| `IPriceOracle` | `src/vendor/IPriceOracle.sol` | Vendored Euler interface ([source](https://github.com/euler-xyz/euler-price-oracle/blob/abfbfc9/src/interfaces/IPriceOracle.sol)) |

## Architecture

```
 keeper (off-chain)                  Euler EVK vault
   | keeperPushPrices(assets,prices)      | getQuote(inAmount, base, quote)
   | pauseAssets(assets)                  v
   v                                 PoppieEulerAdapter
 PoppieEulerOracle                     - converts base → unitOfAccount
   - 18-decimal USD prices               - cached base decimals
   - staleness guard (global + per-asset) - Math.mulDiv (512-bit safe)
   - per-push circuit breaker             - unitOfAccount = USD, address(840)
   - cumulative deviation cap
   - per-asset pause (keeper-or-admin pauses, keeper-push unpauses)
   - admin / keeper roles (two-step admin transfer)
```

### Price guards

Two guards bound what the keeper can push:

1. **Per-push circuit breaker** — caps single-push deviation vs last price.
2. **Cumulative deviation cap** — caps total drift from a rolling anchor,
   preventing a compromised keeper from ratcheting prices via many small
   pushes.

`getPrice` reverts when a stored price is older than `maxPriceAge`,
freezing the asset in Euler until a fresh price is written. Staleness
is configurable at two levels:

- a global `maxPriceAge` set at deployment and via `setMaxPriceAge`,
- a per-asset override via `setAssetMaxPriceAge(asset, seconds)`. A
  non-zero per-asset value takes precedence; zero falls back to the
  global value. This lets the operator tighten the window on liquid
  names and loosen it on assets with legitimate update gaps without
  affecting other assets.

### Per-asset pause

The keeper (or admin) can call `pauseAssets` to immediately freeze
specific assets — `getPrice` reverts with `AssetIsPaused` and
`keeperPushPrices` rejects pushes to paused assets. This is used when
the Ondo halt gate signals a corporate action (split, earnings halt,
trading suspension). Pausing zeros all price state, so the next read
requires admin to re-seed via `adminSetPrice`.

Recovery is a deliberate two-step admin-then-keeper handshake:

1. Admin calls `adminSetPrice(asset, recoveryPrice)` to inject a
   reference price (still paused).
2. The keeper's next `keeperPushPrices` call that passes both guards
   auto-unpauses the asset.

This intentionally couples the unpause to a fresh keeper push that
clears the per-push circuit breaker and cumulative cap, so an unpaused
asset is always backed by a price that has passed the keeper-side
guards rather than just an admin force-write. There is no separate
`adminUnpause` primitive — the auditor (L-02) noted that this couples
recovery to keeper availability, which is the accepted operational
trade-off.

### Recovery

When a legitimate price move exceeds either guard, admin calls
`adminSetPrice` to inject the post-move price (bypassing both guards,
resetting the anchor) and unfreeze in one tx. `adminSetPrice` works on
paused assets so admin can set the recovery price before unpausing.

### Adapter

**PoppieEulerAdapter** implements Euler's `IPriceOracle` (ERC-7726).
Bases must be registered with explicit decimals. The conversion exponent
is always non-negative (baseDec <= 18, quoteDec <= 18).

**ERC-7726 status note.** ERC-7726 is currently a draft and the EIP
explicitly says it should not be relied on in production. We implement
it because Euler V2's vault layer consumes the interface. Integrators
should NOT assume any cross-protocol semantic guarantees from "ERC-7726
compliance" beyond what `PoppieEulerAdapter` documents directly. The
underlying oracle (`PoppieEulerOracle`) is the sole source of truth and
enforces freshness, the circuit breaker, and the cumulative-drift cap.

**Base registration.** `registerBase` requires the base to be
configured on the master oracle first (catches typos / missed
`configureAssets` calls) and cross-checks the supplied decimals against
the token's own `decimals()` when present. Tokens that don't implement
`decimals()` are still accepted with the admin-supplied value.

## Dependencies

| Dependency | Version | Usage |
|---|---|---|
| `forge-std` | v1.16.1 | Test framework (submodule) |
| `openzeppelin-contracts` | v5.6.1 | `Math.mulDiv` only (submodule) |
| `euler-price-oracle` | — | `IPriceOracle` vendored into `src/vendor/`, submodule removed |

## Build & test

```bash
git clone --recurse-submodules <repo-url>
cd poppie-oracle
forge build
forge test
```

127 tests across 5 test suites:

| File | Coverage |
|---|---|
| `PoppieEulerOracle.t.sol` | Unit: push, getPrice, staleness (global + per-asset), roles, circuit breaker, cumulative cap, two-step admin, pause/unpause, anchor rotation |
| `PoppieEulerAdapter.t.sol` | Unit: quote conversion, decimals cross-check, registration (incl. oracle-not-ready), unregistration |
| `PoppieEulerOracle.invariant.t.sol` | Invariants: price positivity, timestamp sanity, config persistence |
| `PoppieEulerAdapter.symbolic.t.sol` | Symbolic/Halmos: quote math equivalence proofs |
| `PoppieEuler.review.t.sol` | Review-oriented property tests |

## Deploy scripts

```bash
# deploy oracle + adapter
source .env
forge script script/DeployDev.s.sol --rpc-url $BSC_RPC_URL --broadcast

# configure 25 assets + register bases
forge script script/ConfigureDev.s.sol --rpc-url $BSC_RPC_URL --broadcast
```

The dev scripts load `DEPLOYER_KEY` from the environment for
repeatability. Audit L-03 noted this as an anti-pattern — production
deployments should use a Foundry keystore (`cast wallet import`,
`--account`), a hardware signer (`--ledger`, `--trezor`), or a
KMS-backed signer instead. See the script NatSpec for context.

## Static analysis & external review

Analyzed with Slither, Aderyn, Mythril, and Solhint. Zero high or medium
findings from any tool. Remaining lows are accepted design choices
(timestamp comparisons in a price oracle, wide pragma, loop reverts for
atomicity).

External preliminary security review by **Chain Defenders** (June 2026,
report under `audit/`) — 0 High, 0 Medium, 3 Low, 6 Informational, all
addressed in this codebase. Security grade: 97/100.
