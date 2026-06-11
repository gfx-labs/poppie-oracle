# Poppie Euler Oracle

Custom oracle contracts for the Poppie x Euler V2 lending market (tokenized
US equities as collateral, USDT borrowable).

## Deployments

| Network | Contract | Address |
|---------|----------|---------|
| BSC (dev) | `PoppieEulerOracle` | [`0x3e33Dc73731E6103B3040CC95672C10cBe953418`](https://bscscan.com/address/0x3e33Dc73731E6103B3040CC95672C10cBe953418) |
| BSC (dev) | `PoppieEulerAdapter` | [`0x0c141b9591e55d07260cE4eb371e2C7757717e6A`](https://bscscan.com/address/0x0c141b9591e55d07260cE4eb371e2C7757717e6A) |

Dev deployment parameters:
- `maxPriceAge`: 3600s (1 hour)
- `anchorWindow`: 86400s (24 hours)
- `unitOfAccount`: `address(840)` (USD), 18 decimals
- 25 Ondo GM tokens configured (matching BSC production asset set)
- Admin: `0xDDeFb8145fA286195f091E3D7749e22B53Bb28bF`
- Keeper: `0x9e77D62f664cb1ebe40C0629841e69Dbf7f646e1` (GCP KMS)

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
   v                                       v
 PoppieEulerOracle  <------ reads ------  PoppieEulerAdapter
   - 18-decimal USD prices                  - converts base → unitOfAccount
   - staleness guard (maxPriceAge)          - cached base decimals
   - per-push circuit breaker               - Math.mulDiv (512-bit safe)
   - cumulative deviation cap               - unitOfAccount = USD, address(840)
   - admin / keeper roles (two-step admin transfer)
```

**PoppieEulerOracle** stores keeper-pushed 18-decimal USD prices. Two
guards bound what the keeper can push:

1. **Per-push circuit breaker** — caps single-push deviation vs last price.
2. **Cumulative deviation cap** — caps total drift from a rolling anchor,
   preventing a compromised keeper from ratcheting prices via many small
   pushes.

`getPrice` reverts when a stored price is older than `maxPriceAge`,
freezing the asset in Euler until a fresh price is written.

**Recovery:** when a legitimate move exceeds either guard, admin calls
`adminSetPrice` to inject the post-move price (bypassing both guards,
resetting the anchor) and unfreeze in one tx.

**PoppieEulerAdapter** implements Euler's `IPriceOracle`. Bases must be
registered with explicit decimals. The conversion exponent is always
non-negative (baseDec <= 18, quoteDec <= 18).

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

80 tests across 4 test suites:

| File | Coverage |
|---|---|
| `PoppieEulerOracle.t.sol` | Unit: push, getPrice, staleness, roles, circuit breaker, cumulative cap, two-step admin |
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
