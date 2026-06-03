# Architecture Understanding

## VaultFactory

`VaultFactory` is currently better understood as a vault registry, not a factory.

The vault deployment flow has moved off-chain through scripts/helpers, while the old factory entrypoints are disabled and revert with `UseOffchainDeployer`. The active responsibility of `VaultFactory` is to register already deployed `CoreVault` instances and emit indexing events.

This registry is mostly used by the subgraph to discover new vaults and add them to its indexed system. Once indexed, the frontend can query the subgraph for the available vault list, vault metadata, lifecycle status, and production/deprecation events.

### Current Registration Flow

`registerVault(address vault, bytes initData)` is owner-gated and performs a minimal consistency check:

- decodes registration metadata from `initData`
- checks that `ICoreVault(vault).asset()` matches the configured asset
- stores the vault address in `deployedVaults`
- stores `vaultIndexPlusOne[vault]` as the constant-time membership/index source of truth
- emits vault discovery/status events for the subgraph

## ERC4626Module

`ERC4626Module` is the user-facing asset entry and force-exit module for
`CoreVault`. It is stateless on its own: calls execute through `delegatecall`,
so the module reads and writes the calling vault's `CoreStorage`, `FeeStorage`,
and `FixedMaturityStorage`.

Standard ERC-4626 `deposit`, `mint`, `withdraw`, and `redeem` calls enter through
explicit `CoreVault` wrappers. Additional functions such as `depositFor`,
slippage-protected overloads, `forceWithdraw`, and `forceWithdrawAll` enter
through the fallback selector router. The module uses CoreVault processor
callbacks to mint, burn, transfer, and spend allowances for vault shares.

### Responsibility Split

- `deposit`, `depositFor`, and `mint` perform atomic asset entry.
- `withdraw` and `redeem` always revert with `AsyncWithdrawalRequired`.
- normal user exits are handled by `QueueModule.requestClaim`.
- `forceWithdraw` is an exact-asset emergency exit that reverts if liquidity is insufficient.
- `forceWithdrawAll` burns all caller shares and pays best-effort assets from the available liquidity waterfall.

### Deposit and Mint Flow

Both entry paths enforce fixed-maturity state, deposit pause flags, reentrancy
protection, fresh warm NAV, and configured deposit limits before minting shares.

For `deposit`, the module deducts the deposit fee from the asset amount,
converts the net assets into user shares, transfers the assets into the vault,
mints gross shares to the receiver, and transfers the fee shares from the
receiver to the fee collector. This keeps the deposit fee non-dilutive.

For `mint`, the module calculates the net assets required for the exact requested
shares, grosses that amount up for the deposit fee, transfers the gross assets
into the vault, mints the requested shares plus fee shares, and transfers the
fee shares to the fee collector.

### Force Exit Flow

Both force exits are available for OpenEnded vaults and FixedMaturity vaults in
the `Active` state. They bypass the normal queue, deposit lock period, and epoch
cap, but still enforce withdrawal pause flags and configured per-transaction /
per-block withdrawal limits.

`forceWithdraw` calculates the shares required for an exact asset amount,
applies FORCE fee shares, validates the caller's `maxShares`, sources liquidity
from hot assets, the warm buffer, and the caller's strategy plan, then burns
shares and pays the exact requested assets.

`forceWithdrawAll` calculates a target value from all caller shares, attempts to
source liquidity through hot assets, warm force refill, and strategy force
redemption, burns all remaining shares, and pays
`min(hot balance, target assets)`. It guarantees exit from the share position,
not full-value asset delivery.

## SystemSealer

`SystemSealer` is the on-chain certification contract for the final production state of a `CoreVault` deployment. It is not part of normal vault runtime; it is used once near the end of deployment to confirm that governance, routing, and connected components are in the expected state.

`prepareSeal(SealConfig config)` can only be called by `config.rootTimelock`. It checks that the vault is owned by the root timelock, guardian/vetoer are correct, routing is frozen, component timelocks are enabled, owner selectors are protected, connected components are governed by the timelock, deployer roles are removed, and the dead deposit is seeded.

If the checks pass, `SystemSealer` computes a `configHash` and calls `CoreVault.prepareSeal(configHash)`. `CoreVault` stores that hash in `CoreStorage.pendingSealHash`.

The final step is `CoreVault.sealFinalState(expectedHash)`, called by the vault owner/root timelock. It verifies `expectedHash == pendingSealHash` and sets `FLAG_SYSTEM_SEALED`. After this, the vault rejects further mutable setup actions such as changing authorized modules or assigning another sealer.
