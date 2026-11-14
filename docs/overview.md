# Overview

`CoreVault` is a non-custodial ERC-4626 vault for USDC on Arbitrum. It is a Diamond-lite proxy: unknown selectors reach `fallback()`, which looks up the module in `SelectorRegistry`, checks the caller's role and `delegatecall`s the module. Modules run in the vault's context and share state through four EIP-7201 namespaced storage slots (`CoreStorage`, `FeeStorage`, `QueueStorage`, `FixedMaturityStorage`). The selector registry is immutable after deployment.

The vault runs in one of two modes: Open Ended (continuous deposits and exits) or Fixed Maturity (funding window, activation, exits at maturity), driven by `FixedMaturityModule`.

## Source layout

| Path | Contents |
|---|---|
| `src/core/CoreVault.sol` | ERC-4626 entry point and dispatcher |
| `src/core/SystemSealer.sol` | Freezes the routing table and module set |
| `src/core/modules/` | Delegatecall modules (`ERC4626Module`, `EpochedQueueModule`, `AdminModule`, `LiquidityOpsModule`, `FixedMaturityModule`) and standalone contracts (`BufferManager`, `FeeCollector`, `BatchGuardrails`, `StrategyRouter`, `StrategyHealthRegistry`, `StrategyScorer`, `PriceOracleMiddleware`, `RouterAllocationPolicy`, `RouterRebalanceGuard`, `ExecutionMemory`, `Incentives`, `IncentivesEngine`) |
| `src/core/storage/` | EIP-7201 storage structs and slot constants |
| `src/core/libraries/` | Logic shared by modules (`SelectorRegistry`, `QueueLib`, `ExitEngineLib`, `ExitFeeLib`, `SettlementLib`, `TimelockLib`, `WithdrawalCapLib`, `OracleValuationLib`, `NavSmoothingLib`, `Errors`, `Events`) |
| `src/core/mixins/` | Reusable vault behaviour (`ClaimsMixin`, `FeeMixin`, `PermitOpsMixin`, `Roles`, `Ownable2StepMixin`) |
| `src/core/config/GlobalConfig.sol` | Protocol-wide parameters and fee caps |
| `src/adapters/warm/` | Warm USDC lending adapters (Aave V3, Morpho Blue) |
| `src/automation/` | Chainlink-compatible keepers (`VaultUpkeep`, `FixedMaturityVaultUpkeep`, `ClaimSettlementUpkeep`) |
| `src/governance/` | `IncentivesTimelock`, `RecoveryGate` |
| `src/registry/`, `src/factory/`, `src/lens/` | `ProtocolRegistryWithTimelock`, `VaultFactory`, `CoreVaultLens` (read-only views) |
| `src/interfaces/`, `src/libs/`, `src/mocks/` | Interfaces, math helpers (`FixedPoint`, `MathUtils`, `Percentage`), `ERC20Mock` |
| `script/` | Deployment, configuration and maintenance scripts |
| `halmos/` | Symbolic tests, with their own `foundry.toml` |
| `broadcast/` | Deployment records and address files |

Dependencies are git submodules in `lib/`: `forge-std`, `openzeppelin-contracts` and `openzeppelin-contracts-upgradeable`. `remappings.txt` also maps `@multyr-core/` to `src/` and `@multyr-periphery/` to `../src/periphery/`, which exists only when the periphery repository is checked out alongside.

## Build configuration

`foundry.toml` defines a single `default` profile: Solidity 0.8.28, optimizer at 200 runs, `via_ir = true`, EVM `shanghai`. Fuzz runs are 256; invariant runs are 256 at depth 50. `fs_permissions` allows reading the repository and writing `./broadcast`. Formatting is 100 columns, 4 spaces, double quotes. A `via_ir` build is slow: the first `forge build` can take several minutes.

## Test layout

| Path | Purpose |
|---|---|
| `test/unit/core/` | Vault, modules, mixins, libraries, fees, queue, force-exit, economic exit, governance handover |
| `test/unit/automation/`, `test/unit/factory/`, `test/unit/fixed-maturity/` | Keeper, factory and Fixed Maturity unit tests |
| `test/integration/` | Vault wired with buffer manager, warm adapters, upkeeps and factory; deployment equivalence |
| `test/invariants/` | Handler-based `StdInvariant` suites (claims queue, economic exit, governance seal, recovery, pause matrix, warm adapters) |
| `test/security/` | EIP-7201 compliance, share price collapse, lock period protection, vault security suite |
| `test/incident-sim/` | End-to-end incident scenarios |
| `test/sprint-test/` | Proof-of-concept regressions for audit findings |
| `test/fork/` | Arbitrum mainnet fork tests; need network access |
| `test/helpers/`, `test/mocks/` | Base test, deploy helper, mocks (USDC, Aave, strategies, oracle, params) |
| `halmos/test/` | Symbolic tests for the selector registry and fixed-maturity guards |

Vault tests normally extend `test/helpers/BaseVaultTest.t.sol` and deploy through `test/helpers/CoreDeployHelper.sol`.

## Running tests

CI pins Foundry `v1.7.1`; newer nightlies change cheatcode and gas behaviour and break harnesses. Fetch the submodules, then build:

```bash
git submodule update --init --recursive
forge build
```

| Goal | Command |
|---|---|
| Everything except fork tests (what CI runs) | `forge test --no-match-path "test/fork*" -vv` |
| One file | `forge test --match-path test/unit/core/CoreVault_Roles.t.sol -vvv` |
| One test | `forge test --match-test testName` |
| One contract | `forge test --match-contract EpochedQueueModuleTest` |
| Invariants only | `forge test --match-path "test/invariants/*"` |
| Deeper fuzzing | `FOUNDRY_FUZZ_RUNS=2000 FOUNDRY_INVARIANT_RUNS=1000 forge test --match-path "test/invariants/*"` |
| Gas report | `forge test --no-match-path "test/fork*" --gas-report` |
| Coverage summary | `forge coverage --no-match-path "test/fork*" --report summary` |
| Fork tests | `ARBITRUM_RPC_URL=<url> forge test --match-path "test/fork/*" -vv` |
| Symbolic tests | `cd halmos && halmos` (requires Halmos) |

Fork tests read `ARBITRUM_RPC_URL` (default: the public Arbitrum endpoint); `EconomicExit_ArbitrumFork` also reads `ARBITRUM_FORK_BLOCK`. They read chain state and send no transactions.

Before committing Solidity changes:

```bash
forge fmt --check
forge build
forge test --no-match-path "test/fork*"
```

## Related

- [`architecture.md`](architecture.md), [`modules.md`](modules.md): the vault and module design.
- [`testing.md`](testing.md): the wider test-strategy reference (symbolic and property-based layers).
- [`deployment.md`](deployment.md), [`wiring.md`](wiring.md): deploying and wiring the contracts.
