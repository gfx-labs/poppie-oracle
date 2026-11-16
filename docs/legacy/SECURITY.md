# Security notes & threat model (for reviewers)

## System context
Poppie runs an Euler V2 market on BSC where tokenized US equities (Ondo `*on` tokens)
are collateral and USDT is the only borrowable asset. Equity prices are not available
on a continuous on-chain feed, so Poppie operates a **trusted off-chain keeper** that
computes a final 18-decimal USD price per asset and pushes it on-chain.

`PoppieEulerOracleV2` stores those pushed prices. `PoppieEulerAdapterV2` adapts the
stored price to Euler's `IPriceOracle` (ERC-7726) quote interface that the EVK vaults
call. USDT is priced separately by an unmodified `FixedRateOracle` (1:1 to USD) so a
keeper outage on an equity feed cannot freeze the borrowable asset.

## Trust assumptions (by design)
- **The keeper is trusted** to push correct prices. Mitigations in-contract: per-asset
  circuit-breaker threshold (bounds a single update's movement), strictly-positive price
  checks, and a `maxPriceAge` staleness guard so a stalled keeper freezes reads rather
  than serving stale data.
- **Admin (a multisig Safe) is trusted** for role/config changes (keeper address,
  `maxPriceAge`, circuit-breaker thresholds, asset configuration).
- Equities only trade during market sessions; outside them `getPrice` reverting (freeze)
  is the intended, safe behavior (borrows/withdrawals/liquidations pause for that asset).

## Areas we'd most like scrutinized
1. **Staleness / freeze logic** — boundary conditions of `maxPriceAge`, the
   `maxPriceAge == 0` disable path, and per-asset timestamp handling.
2. **Adapter scaling math** — `PoppieEulerAdapterV2` decimal conversion using
   `Math.mulDiv`; the `unitOfAccountDecimals <= 18` invariant and base-decimal bounds
   that keep the exponent non-negative (no underflow / rounding abuse).
3. **Circuit breaker** — whether the threshold can be bypassed or mis-set to permit a
   bad price, and behavior on first price (`lastPrice == 0`).
4. **Access control** — keeper vs admin separation; role-transfer safety (zero-address
   guards present).
5. **Price direction / inversion** in the adapter quote (base↔quote correctness).

## Known design decisions (not bugs)
- Off-hours/weekend/holiday price freeze is intentional (tokenized equities).
- The keeper is a centralized component; decentralizing it is out of scope for V2.
- `FixedRateOracle` is used unmodified from euler-price-oracle.
