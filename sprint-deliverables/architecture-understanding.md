# Architecture Understanding

## VaultFactory

`VaultFactory` is currently better understood as a vault registry, not a factory.

The vault deployment flow has moved off-chain through scripts/helpers, while the old factory entrypoints are disabled and revert with `UseOffchainDeployer`. The active responsibility of `VaultFactory` is to register already deployed `CoreVault` instances and emit indexing events.

This registry is mostly used by the subgraph to discover new vaults and add them to its indexed system. Once indexed, the frontend can query the subgraph for the available vault list, vault metadata, lifecycle status, and production/deprecation events.

## Current Registration Flow

`registerVault(address vault, bytes initData)` is owner-gated and performs a minimal consistency check:

- decodes registration metadata from `initData`
- checks that `ICoreVault(vault).asset()` matches the configured asset
- stores the vault address in `deployedVaults`
- stores `vaultIndexPlusOne[vault]` as the constant-time membership/index source of truth
- emits vault discovery/status events for the subgraph
