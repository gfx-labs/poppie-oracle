# Poppie Euler Oracle

Custom oracle contracts for the Poppie x Euler V2 lending market (tokenized
US equities as collateral, USDT borrowable).

## Deployments

| Network | Contract | Address |
|---------|----------|---------|
| BSC (dev) | `PoppieEulerOracle` | [`0xAECe46000C265e72C7Ba972F95EEe1cF80af549F`](https://bscscan.com/address/0xAECe46000C265e72C7Ba972F95EEe1cF80af549F) |
| BSC (dev) | `PoppieEulerAdapter` | [`0x1c3e111efc22032952914c23E907C20676280d33`](https://bscscan.com/address/0x1c3e111efc22032952914c23E907C20676280d33) |

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
   - staleness guard (maxPriceAge)        - Math.mulDiv (512-bit safe)
   - per-push circuit breaker             - unitOfAccount = USD, address(840)
   - cumulative deviation cap
   - per-asset pause (keeper pauses, admin unpauses)
   - admin / keeper roles (two-step admin transfer)
```

### Price guards

Two guards bound what the keeper can push:

1. **Per-push circuit breaker** — caps single-push deviation vs last price.
2. **Cumulative deviation cap** — caps total drift from a rolling anchor,
   preventing a compromised keeper from ratcheting prices via many small
   pushes.

`getPrice` reverts when a stored price is older than `maxPriceAge`,
freezing the asset in Euler until a fresh price is written.

### Per-asset pause

The keeper (or admin) can call `pauseAssets` to immediately freeze
specific assets — `getPrice` reverts with `AssetPaused` and
`keeperPushPrices` rejects pushes to paused assets. This is used when
the Ondo halt gate signals a corporate action (split, earnings halt,
trading suspension).

Only admin can call `unpauseAssets` — unpausing is a deliberate
decision after verifying price data is good. A compromised keeper can
pause (DoS) but cannot unpause.

### Recovery

When a legitimate price move exceeds either guard, admin calls
`adminSetPrice` to inject the post-move price (bypassing both guards,
resetting the anchor) and unfreeze in one tx. `adminSetPrice` works on
paused assets so admin can set the recovery price before unpausing.

### Adapter

**PoppieEulerAdapter** implements Euler's `IPriceOracle` (ERC-7726).
Bases must be registered with explicit decimals. The conversion exponent
is always non-negative (baseDec <= 18, quoteDec <= 18).

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

87 tests across 5 test suites:

| File | Coverage |
|---|---|
| `PoppieEulerOracle.t.sol` | Unit: push, getPrice, staleness, roles, circuit breaker, cumulative cap, two-step admin, pause/unpause |
| `PoppieEulerAdapter.t.sol` | Unit: quote conversion, decimals, registration, unregistration |
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

## Static analysis

Analyzed with Slither, Aderyn, and Solhint. Zero high or medium findings.
Remaining lows are accepted design choices (timestamp comparisons in a
price oracle, wide pragma, loop reverts for atomicity).
