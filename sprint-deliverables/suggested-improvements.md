# Suggested Improvements

## VaultFactory

### Changes Done

- `registerVault` now decodes `DeployTypes.VaultRegistrationConfig` instead of the full deployment config, keeping registry metadata separate from deployment wiring.
- Registry storage now uses `deployedVaults` plus `vaultIndexPlusOne`, giving enumerable reads, constant-time membership checks, duplicate protection, and swap-and-pop removal.
- The `index + 1` pattern keeps `0` available as the "not registered" sentinel while still supporting vaults stored at array index `0`.

### Open Improvements

- **Rename to `VaultRegistry`**: the contract no longer deploys vaults; it registers, removes, deprecates, and emits status events for off-chain deployments.
- **Use transferable ownership**: replace `immutable owner` with `Ownable2Step` so registry control can move safely between governance, timelocks, or multisigs.
- **Gate lifecycle/status calls**: make `deprecateVault` and `setVaultStatus` revert with `VaultNotFound` when `vaultIndexPlusOne[vault] == 0`.
- **Choose one creation event**: `registerVault` emits `VaultDeployed`, `Events.VaultCreated`, and `Events.VaultProductionReady`; keep duplicates only if the subgraph still needs them.
- **Prefer typed registration input**: replace `bytes initData` with `VaultRegistrationConfig calldata` or explicit args unless encoded bytes are required for tooling compatibility.
- **Validate metadata fields**: explicitly reject zero `cfg.asset`, `cfg.owner`, and `cfg.feeCollector`.
- **Add pagination if needed**: use a paginated getter such as `getDeployedVaults(uint256 start, uint256 limit)` if the registry is expected to grow large.

## SystemSealer

### Open Improvements

- **Make `configHash` deterministic**: remove `block.timestamp`, add `computeConfigHash(config)`, and schedule `sealFinalState(precomputedHash)` with the same deterministic value. Include every `SealConfig` field in the hash.
- **Strengthen dead-deposit verification**: check actual dead-share balance or a minimum seeded amount, not only `isDeadDepositDone()`.
- **Verify live vault wiring**: confirm the config addresses match the addresses stored in `CoreVault`, including router, buffer manager, health registry, fee collector, selector registry, and other critical components.
