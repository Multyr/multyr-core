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

## ERC4626Module

### Open Improvements

- **Authorize `depositFor` payers**: require `msg.sender == payer`, consume a dedicated payer approval, or use a signed permit before pulling assets from a third party. An ERC-20 allowance to the vault should not allow an arbitrary caller to redirect the payer's funds into shares owned by another receiver. See `DepositFor_UnauthorizedPayer_POC.t.sol`.
- **Protect `forceWithdrawAll` against unbounded shortfall**: add a `minAssetsOut` parameter or a separate exact/protected variant that reverts when best-effort liquidity extraction returns too little. If partial emergency exits remain supported, consider burning shares only for assets actually paid or preserving a residual claim for unpaid value. See `ForceWithdrawAll_SlippagePOC.t.sol`.
- **Rename or clearly document `forceWithdrawAll`**: the function guarantees removal of the caller's share position, not delivery of the full calculated asset value. A name such as `emergencyExitBestEffort` would make the risk clearer to integrators.
- **Run slippage checks after warm NAV refresh**: the slippage-protected `deposit` and `mint` overloads calculate their expected values before `_depositInternal` / `_mintInternal` can refresh stale warm NAV. If the refresh changes NAV, the actual shares or assets may violate the caller's `minShares` or `maxAssets` limit. Refresh first or validate the final computed result immediately before asset transfer.
- **Align `mint` side effects with `deposit`**: `_depositInternal` notifies incentives and can trigger fixed-maturity funding auto-close, while `_mintInternal` does neither. Apply the same hooks to both entry paths, or explicitly document and test why exact-share minting should behave differently.

## SystemSealer

### Open Improvements

- **Make `configHash` deterministic**: remove `block.timestamp`, add `computeConfigHash(config)`, and schedule `sealFinalState(precomputedHash)` with the same deterministic value. Include every `SealConfig` field in the hash.
- **Strengthen dead-deposit verification**: check actual dead-share balance or a minimum seeded amount, not only `isDeadDepositDone()`.
- **Verify live vault wiring**: confirm the config addresses match the addresses stored in `CoreVault`, including router, buffer manager, health registry, fee collector, selector registry, and other critical components.
