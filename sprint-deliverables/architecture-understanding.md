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

## SystemSealer

`SystemSealer` is the on-chain certification contract for the final production state of a `CoreVault` deployment. It is not part of normal vault runtime; it is used once near the end of deployment to confirm that governance, routing, and connected components are in the expected state.

`prepareSeal(SealConfig config)` can only be called by `config.rootTimelock`. It checks that the vault is owned by the root timelock, guardian/vetoer are correct, routing is frozen, component timelocks are enabled, owner selectors are protected, connected components are governed by the timelock, deployer roles are removed, and the dead deposit is seeded.

If the checks pass, `SystemSealer` computes a `configHash` and calls `CoreVault.prepareSeal(configHash)`. `CoreVault` stores that hash in `CoreStorage.pendingSealHash`.

The final step is `CoreVault.sealFinalState(expectedHash)`, called by the vault owner/root timelock. It verifies `expectedHash == pendingSealHash` and sets `FLAG_SYSTEM_SEALED`. After this, the vault rejects further mutable setup actions such as changing authorized modules or assigning another sealer.
