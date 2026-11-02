# Poppie on Euler V2 (Arbitrum)

Lending against tokenized US equities on Euler V2, on Arbitrum. Borrow asset: USDC. Long only. Collateral is classed
blue chip or long tail and held in per-asset escrow vaults; USDC is lent from four hubs (Prime, M1, M2, M3) and two
Euler Earn vaults. Prices come from Poppie's own keeper-fed oracle through a three-state adapter (Live, Unconfirmed,
Closed). Risk parameters are changed through a bounded risk steward, without a timelock; structural changes go
through a 48h timelock.

Design: `docs/ARCHITECTURE.md` (intent), `docs/V2_PLAN.md` (plan), `docs/CONTRACT_SPEC.md` (interfaces and
behaviour), `docs/SECURITY.md` (threat model), `docs/RUNBOOKS.md`, `docs/AUDIT_SCOPE.md`. v1 (BSC) lives at the
`v1-bsc` tag; `main` holds the audited v1 code.

> **Status:** initial v2 draft complete on `scale` (contracts, scripts, local/integration/fork tests). Not deployed.
> Not audited.

## Contracts

| Path | Contract | Role |
| --- | --- | --- |
| `src/oracle/PoppieEulerOracle.sol` | `PoppieEulerOracle` | Price store and state machine: keeper pushes (ABI and 14-byte packed), class bounds, `K_CONFIRM`, `n`-push fallback, pause |
| `src/oracle/PoppieEulerAdapter.sol` | `PoppieEulerAdapter` | Immutable Euler `IPriceOracle`: mid for liquidations (reverts unless Live), bid/ask for borrowing (haircut while Closed or Unconfirmed) |
| `src/fee/PoppieFeeRouter.sol` | `PoppieFeeRouter` | Origination fee: borrows go to the router, which forwards net-of-fee within the same EVC batch |
| `src/hooks/PoppieHubHook.sol` | `PoppieHubHook` | Hub hook: borrow validation, status-check gate for the fee, borrow/liquidation pauses, no flash loans |
| `src/hooks/PoppieEscrowHook.sol` | `PoppieEscrowHook` | Escrow hook: blocks every deposit route while the asset is Closed or deposits are paused |
| `src/wrapper/PoppieBalanceWrapper.sol` | `PoppieBalanceWrapper` | Wrapper for balance-changing and dividend-paying tokens; dividends are swept to the reserve |
| `src/wrapper/PoppieWrapperFactory.sol` | `PoppieWrapperFactory` | One wrapper per token (CREATE2), seed deposit, dividend recipient |
| `src/governance/PoppieRouterGovernor.sol` | `PoppieRouterGovernor` | Governor of the EulerRouter: add-only routes, wrappers and verified escrow vaults |
| `src/steward/PoppieRiskSteward.sol` | `PoppieRiskSteward` | Bounded LTV and cap changes on hubs and escrows (holds the Governor's `setLTV`/`setCaps` roles) |
| `src/access/` | `PoppieAccessControl`, `Roles` | Shared role base and role ids |
| `src/interfaces/` | | Exact external interfaces (fixed by POP-5) |

Euler core is used at canonical Arbitrum addresses: EVC, EVK factory and implementation, EulerRouter (deployed per
Poppie), `GovernorAccessControl`, kink IRM factory, Euler Earn, lenses. See `test/fork/ForkBase.sol` for the
addresses checked on chain.

## Build and test

```bash
git clone <repo> && cd <repo>
./scripts/init-deps.sh        # submodules, plus the few nested ones the build needs
forge build && forge fmt --check
forge test --no-match-path "test/fork/**"            # local: unit, fuzz, invariant, symbolic, integration, scripts, bench
forge test --match-path "test/fork/**" --fork-url arbitrum   # Arbitrum fork (RPC alias from foundry.toml)
slither . --config-file slither.config.json --fail-medium
```

Do not use `git submodule update --init --recursive`: it clones every nested dependency of the Euler repos, none of
which are compiled here.

| Directory | Contents |
| --- | --- |
| `test/unit` | Per-contract unit tests, every bound at its boundary |
| `test/fuzz`, `test/invariant`, `test/symbolic` | Oracle model fuzzing, wrapper inflation, invariants (oracle, fee router, wrapper, steward), Halmos-style `check_` properties |
| `test/integration` | Full stack on a local EVK (`FullStackFixture`): fees, price states, wrapper pricing, steward on real hubs, bad debt, 500-collateral scale |
| `test/scripts` | `Deploy` + 100-asset listing + `ConfigCheck`, reproducibility, negative checks |
| `test/fork` | Arbitrum fork: canonical Euler compatibility, Earn acceptance, 300/500-collateral lens gas, launch rehearsal, reserve Roles scope. Skips when the RPC alias cannot be resolved |
| `test/bench` | Gas: pushes and confirms (100/250/500), steward batches (500) |

Fork tests are rate-limited by a free-tier RPC: run one fork suite at a time. Never put an RPC URL or key on the
command line; use the `arbitrum` alias.

## Scripts (simulation, anvil or fork only)

Agents never broadcast to a live network (`AGENTS.md`); the Arbitrum launch (POP-18) is executed by humans.

| Script | Usage |
| --- | --- |
| `script/Deploy.s.sol` | `forge script script/Deploy.s.sol --sig "run(string)" config/deploy.<net>.json`. Deploys and wires the stack, hands `DEFAULT_ADMIN_ROLE` to the timelock and renounces the deployer; writes `deployments/<chainid>.json` |
| `script/BuildListingBatch.s.sol` | `--sig "run(string,string,string,string,address)" <step> <name> config/assets.json deployments/<chainid>.json <safe>` with step `approvals` (MS_ADMIN timelock batch), `stage1` (deployer: wrappers and escrows) or `stage2` (MS_OPS Safe batches). Writes Safe Transaction Builder JSON to `batches/<name>/`; byte-identical for the same input |
| `script/ConfigCheck.s.sol` | `--sig "run(string,string,string,string)" config/deploy.<net>.json deployments/<chainid>.json config/assets.json batches/<name>/1-stage1.json`. Fails on any diff, a zero fee receiver, or a role left with the deployer |
| `script/local/LocalRehearsal.s.sol` | `--sig "run(uint256)" 100 --rpc-url http://127.0.0.1:8545` against a fresh anvil: local Euler core + deploy + listing + ConfigCheck, simulation only |

Config: `config/deploy.example.json` (placeholders), `config/deploy.arbitrum.json` (canonical Euler addresses; Poppie
role holders and the USDC/USD oracle are zero until filled in, and `Deploy` rejects zeros), `config/assets.schema.json`
and `config/assets.example.json`. IRM curves, caps and Earn values in the configs are placeholders pending risk
sign-off.

## Dependencies

`solc 0.8.24` and `evm_version = cancun` match Euler's Arbitrum deployment. Each Euler repository is pinned to the
commit behind the contract deployed on Arbitrum (chain 42161), taken from the bytecode-verified `verify/manifest.json`
in [euler-xyz/euler-interfaces](https://github.com/euler-xyz/euler-interfaces):

| Submodule | Commit | Deployed Arbitrum contract it matches |
|---|---|---|
| `lib/ethereum-vault-connector` | `a7d3c29` (v1.0.1) | `EthereumVaultConnector` |
| `lib/euler-vault-kit` | `422bf24` (v1.0.1) | `EVault` implementation |
| `lib/euler-price-oracle` | `f52cb43` | `EulerRouter` source, via evk-periphery's gitlink |
| `lib/evk-periphery` | `96b83f8` (v1.8.0) | `EulerRouterFactory`; source of the Governor |
| `lib/euler-earn` | `b2fd6e6` (v1.0.0) | `EulerEarnFactory` (built by Euler with solc 0.8.26; not compiled here; scripts use minimal interfaces) |
| `lib/openzeppelin-contracts` | `69c8def` (v5.1.0) | the version evk-periphery pins |

`GenericFactory` and `ProtocolConfig` are deployed from EVK `9e3c760`, an older commit than the `EVault`
implementation; the code this repo compiles is the newer `422bf24`. evk-periphery `b54367e` is newer but points at
different EVC/EVK gitlinks than the deployed contracts, so `96b83f8` is kept. `optimizer_runs = 200` differs from
Euler's 20000 on purpose: only Poppie's own bytecode depends on it. euler-price-oracle's `FixedRateOracle` needs a
solady remapping that is not configured, so the USDC/USD oracle is a deployment input.

### Test harness

`test/harness/PoppieTestBase.sol` deploys EVC, EVK factory and implementation, EulerRouter, an Euler Governor, mock
USDC and a mock equity locally, with no fork. Permit2 and the balance tracker are `address(0)` (a codeless non-zero
Permit2 would make EVK's permit2 call "succeed" without moving tokens); fork tests use the real Permit2.
`FullStackFixture` builds the whole Poppie stack on top and lists assets through the real two-stage flow.

## Branches and process

`main` holds audited v1 and is never touched by agents. All v2 work lands on `scale` through PRs that pass CI
(format, build, local tests, Slither). See `AGENTS.md`.
