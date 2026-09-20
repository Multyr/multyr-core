Withdrawal policy supersedes the historical minimum below: use ConfigureWithdrawalPolicy.s.sol for a permanent 100e6 deposit minimum and zero claim floor. No GlobalConfig redeployment is needed.

Latest deployment: 0x16968cA72bE6CBfCaC8A8a87349EE5706f771a2e, via ConfigureOneHourEpoch.s.sol. Epoch = 3600 seconds, minClaimAmount = 1000 raw USDC. Earlier one-day migration below is retained as history.

# GlobalConfig queue setter and Arbitrum migration

## Implemented change

GlobalConfig now exposes governor-only `setDefaultQueue(QueueConfig)` and `setVaultQueueOverride(address, QueueConfig)`. A valid queue has at least one permitted claim, a duration from 1 hour through 30 days, and a claim cooldown no longer than its duration. A zero cooldown remains permitted. Default changes emit `DefaultQueueUpdated`; vault changes emit the existing override event plus `VaultQueueOverrideUpdated` with the full value. Clearing a vault override restores default behavior.

An open epoch reads the configured duration at close time. Changing the current vault to one day therefore also changes its existing epoch's closing eligibility. This does not change the separate CoreStorage immediate-withdrawal cap epoch.

## Getter/setter review

All 29 required `IParamsProvider` function signatures are implemented. The missing queue setter was not a missing getter: `getQueueParams` already existed.

Additional gaps found, intentionally not bundled into this live behavioral change:

| Area | Existing reads | Gap |
|---|---|---|
| Default withdrawal | defaultWithdrawal/getWithdrawalParams | No complete default-withdrawal setter; vault override exists. |
| Default dynamic cap | defaultDynamicCap/getDynamicCapParams | No default setter; existing uncommitted vault setter preserved. |
| Security | defaultSecurity/getSecurityParams/vaultSecurityOverrides | No full default or per-vault security setter. Oracle-specific setters cover only part of this group. |
| Buffer | defaultBuffer/getBufferParams/vaultBufferOverrides | No default or per-vault buffer setter. |
| Strategy risk | defaultStrategy/getStrategyParams/vaultStrategyOverrides | No default or per-vault strategy-risk setter. |
| Full fee fields | defaultFees/getFeeParams/vaultFeeOverrides | Fee setters update BPS fields; no direct configuration path for default perfRateX, crystallization interval, or treasury. |
| Adapter policy | isAdapterAllowed/adapterCap | Getters return constant true/uint256.max rather than consulting stored policy. Stored default/per-vault mappings have no raw public getters. Enforcing them would change routing policy and needs a separate migration plan/test. |
| Legacy lock/cooldown | public legacy fields and getVaultLockPeriod | Legacy mappings lack setters. setDefaultLockPeriod writes defaultLockPeriod, but effective withdrawal and legacy lock getters read defaultWithdrawal.lockPeriod. No effective per-vault cooldown getter uses vaultCooldownOverrides. |

This deployment adds only the queue write paths, and preserves all prior effective behavior outside the target queue duration. The other gaps are documented rather than introducing unreviewed policy changes.

## Migration design

`script/helpers/GlobalConfigMigration.sol` contains `GlobalConfigMigrated`, which inherits GlobalConfig and adds only a constructor-time state import. It has no callable import or arbitrary storage-write facility after deployment. It copies 26 public scalar/struct fields, 25 public address-mapping fields for the inventoried vault/asset, and all 15 override flags. Governance remains RootTimelock from deployment; no temporary EOA governor is introduced. Existing version and all fee-recipient values are preserved exactly.

The old deployment's complete emitted event history was inventoried: one configured vault, one USDC asset-oracle entry, no adapter-policy writes. The constructor fails on an active per-vault adapter-policy override. It is intentionally scoped to this inventoried deployment, not a generic enumerator for arbitrary mapping keys. Re-inventory before reusing it for another deployment.

`script/RedeployGlobalConfig.s.sol` compares raw copied getters and effective parameter getters before scheduling a timelock batch. The batch sets a one-day override preserving the claim limit and cooldown, switches CoreVault.params, and switches StrategyRouter.params atomically. It refuses a changed source provider, governor, vault inventory, queue duration, nonzero timelock delay, or sealed CoreVault.

VaultUpkeep holds an immutable reference to the OLD config. Its only query there is minRebalanceCooldown, which remains identical. Do not retire the old config or change cooldown on just one provider while this upkeep remains in service. A future full pointer cleanup requires replacing VaultUpkeep or keeping that cooldown synchronized.

No forwarding-provider facade is used. The previously drafted OneDayQueueParams experiment was not deployed.

## Validation and operation

Focused tests cover unauthorized callers, bounds, default/override precedence, clearing, fuzzed roundtrips, and preservation of nondefault settings, oracle configuration, governor, and override flags during import. The script adds live simulation postconditions for both consumer pointers and the queue settings.

Simulation and broadcast use DEPLOYER_PRIVATE_KEY from the existing environment, with a derived-address check. Never print the key or pass it on the command line. Deployment, timelock scheduling, and execution are distinct transactions; if execution fails, inspect receipts before retrying. Do not rerun blindly after a partial deployment. The consumer switches and queue override are grouped in one atomic execution batch.
