# VaultFactory

## Changes Done

### `src/factory/VaultFactory.sol`

`registerVault` now decodes `DeployTypes.VaultRegistrationConfig` instead of the full `DeployTypes.DeployConfig`.

This keeps the registry path separate from deployment wiring. The factory only needs vault metadata for registry/subgraph events:

- `asset`
- `name`
- `symbol`
- `owner`
- `feeCollector`

This removes the need for the factory registration path to carry deployment-only fields such as `paramsProvider`, `ecosystem`, `freezeRouting`, and `selectorRegistry`.

The registry storage was also improved from array-only to mapping-plus-array:

- `deployedVaults` remains the enumerable list for frontend, subgraph, and admin reads.
- `vaultIndexPlusOne` provides constant-time membership checks.
- duplicate vault registrations are rejected with `VaultAlreadyRegistered`.
- `removeVault` uses swap-and-pop and keeps the index mapping in sync.

The `index + 1` pattern is used so `0` can mean "not registered" while still allowing vaults stored at array index `0`.

## Suggested Improvements

Rename `VaultFactory` to `VaultRegistry`.

The contract no longer deploys vaults. `createVault` and `createVaultDeterministic` both revert with `UseOffchainDeployer`, while the live behavior is registration, removal, deprecation, and status events. A registry name would match the actual responsibility and reduce confusion for future readers.

Replace `immutable owner` with `Ownable2Step`.

The current owner cannot be transferred. If governance, a timelock, or a multisig needs to change, the registry has to be redeployed or abandoned. `Ownable2Step` would preserve the same access pattern while allowing safe ownership handoff.

Add membership checks to lifecycle/status functions.

`deprecateVault` and `setVaultStatus` currently only reject `address(0)`. They can emit lifecycle/status events for vaults that were never registered. If the registry is intended to be the source of truth, these functions should revert with `VaultNotFound` when `vaultIndexPlusOne[vault] == 0`.

Decide on one canonical registration event.

`registerVault` currently emits:

- `VaultDeployed`
- `Events.VaultCreated`
- `Events.VaultProductionReady`

This may be intentional for subgraph compatibility, but the TODO notes suggest some are redundant. The subgraph should eventually consume one canonical vault-created event, then duplicate events can be removed.

Consider typed registration args instead of `bytes initData`.

`registerVault(address vault, bytes initData)` still feels like a leftover factory-style initializer API. Since the function now expects exactly `VaultRegistrationConfig`, a clearer API would be either:

- `registerVault(address vault, DeployTypes.VaultRegistrationConfig calldata cfg)`
- `registerVault(address vault, address asset, address owner, address feeCollector, string calldata name, string calldata symbol)`

Keep the encoded form only if there is an external deployment tool or ABI compatibility reason.

Validate registration metadata explicitly.

The function checks `vault != address(0)` and asset consistency, but it does not explicitly check `cfg.asset`, `cfg.owner`, or `cfg.feeCollector` for zero. A real `CoreVault` deployment should already prevent bad values, but explicit checks would make the registry safer if called with malformed metadata.

Consider pagination for `getDeployedVaults`.

Returning the full array is fine for a small registry. If many vaults are expected, add a paginated getter like `getDeployedVaults(uint256 start, uint256 limit)` to avoid large return payloads.
