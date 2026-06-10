# Poppie Euler Oracle — Audit Repository

Self-contained Foundry repo for the security review of Poppie's custom oracle
contracts, deployed on BNB Chain (BSC, chainId 56) for the Poppie x Euler V2 lending
market (tokenized US equities as collateral, USDT borrowable).

## Scope

| Contract | File | LoC | Deployed (BSC) |
|---|---|---|---|
| `PoppieEulerOracleV2` | `src/PoppieEulerOracleV2.sol` | 257 | [`0x37c861aF7411a0e1E3b00f038ed0681eCa720944`](https://bscscan.com/address/0x37c861aF7411a0e1E3b00f038ed0681eCa720944) |
| `PoppieEulerAdapterV2` | `src/PoppieEulerAdapterV2.sol` | 220 | [`0xf2c37aa072b980A7054bB281FDC894b64B6EC019`](https://bscscan.com/address/0xf2c37aa072b980A7054bB281FDC894b64B6EC019) |
| `IPoppieEulerOracleV2` (interface) | `src/interfaces/IPoppieEulerOracleV2.sol` | 67 | — |

### Also in scope (as used, not modified)
- **`FixedRateOracle`** — used to price USDT 1:1 against the USD unit of account
  (`address(840)`, 18 decimals). This is an **unmodified** contract from
  [`euler-price-oracle`](https://github.com/euler-xyz/euler-price-oracle) (pulled via the
  `lib/` submodule, not forked). Deployed at
  [`0x969b93eE397B95fF155b2474A350a0800B91F6E0`](https://bscscan.com/address/0x969b93eE397B95fF155b2474A350a0800B91F6E0).
  Covered by `test/FixedRateOracle.t.sol` to pin Poppie's exact configuration.

### Out of scope
- The Euler V2 EVK vaults, router, IRM, and EVC (audited upstream by Euler).
- The off-chain keeper, admin app, and UI.
- Legacy V1 oracle contracts (replaced by V2; not deployed in the live market).

## Architecture (how the two contracts fit together)

```
 keeper (off-chain)                  Euler EVK vault
   | keeperPushPrices(assets,prices)      | getQuote(inAmount, base, quote)
   v                                       v
 PoppieEulerOracleV2  <----- reads ----  PoppieEulerAdapterV2  (implements IPriceOracle / ERC-7726)
   - stores keeper-pushed USD prices       - converts base->unitOfAccount using the
   - getPrice() reverts past maxPriceAge      master oracle's stored price + decimals
   - per-asset circuit-breaker threshold   - unitOfAccount = USD address(840), 18 dp
   - admin / keeper roles
```

- **`PoppieEulerOracleV2`** is the master price store. An off-chain keeper pushes
  final 18-decimal USD prices via `keeperPushPrices`. `getPrice` reverts once a price is
  older than `maxPriceAge` (default 3600s) — an intentional freeze when the underlying
  equity market is closed and no fresh price exists. Includes a per-asset circuit-breaker
  threshold and admin/keeper access control.
- **`PoppieEulerAdapterV2`** implements Euler's `IPriceOracle` (ERC-7726 quote interface).
  It reads the master oracle and converts a `base` amount into the `unitOfAccount`
  (USD, `address(840)`, 18 decimals), applying base-decimal scaling. The
  `unitOfAccountDecimals <= 18` bound guarantees the conversion exponent is non-negative
  (divide-only path, no underflow).

A short design/threat-model note for reviewers is in `docs/SECURITY.md`.

## Build & test

Foundry. Dependencies are git submodules pinned to upstream:

```bash
git clone --recurse-submodules <repo-url>
cd poppie-oracle-audit
forge build
forge test
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### Dependency versions (pinned)
- `forge-std` v1.16.1
- `openzeppelin-contracts` v5.6.1 (only `utils/math/Math.sol` is used)
- `euler-price-oracle` (provides `IPriceOracle` + `FixedRateOracle`)

### Compiler
- solc `0.8.24`, `evm_version = shanghai`, optimizer on, 200 runs (see `foundry.toml`).

## Test suite

85 tests, all passing:

| File | Coverage |
|---|---|
| `PoppieEulerOracleV2.t.sol` | unit tests: push/getPrice/staleness/roles/circuit-breaker/config |
| `PoppieEulerAdapterV2.t.sol` | unit tests: quote conversion, decimals, inversion, registration |
| `PoppieEulerOracleV2.invariant.t.sol` | invariants: price positivity, timestamp sanity, config persistence |
| `PoppieEulerAdapterV2.symbolic.t.sol` | symbolic/property tests on the quote math |
| `PoppieEulerV2.review.t.sol` | review-oriented property tests |
| `FixedRateOracle.t.sol` | pins Poppie's USDT/USD 1:1 config of the Euler FixedRateOracle |

Prior internal tooling run on these contracts (for reference, not a substitute for the
audit): Slither, Semgrep, Foundry fuzzing, Halmos (symbolic), Medusa, and
`slither-mutate` (100% mutation score reported internally).

## Key invariants / properties to verify

- `getPrice` MUST revert when `block.timestamp - lastPriceTimestamp > maxPriceAge`
  (staleness freeze) and when an asset is unconfigured.
- Only `keeper` can `keeperPushPrices`; only `admin` can change roles/config.
- Pushed prices must be strictly positive; negative/zero reverts.
- Adapter conversion: for `unitOfAccountDecimals <= 18` and `baseDecimals <= 18` the
  scaling exponent is always non-negative (no underflow); quote is monotonic in price.
- Circuit-breaker threshold bounds an accepted per-update price movement.
