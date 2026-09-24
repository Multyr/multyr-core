# Insolvency funding runbook

Use this procedure when a Closed cohort cannot fund because NAV is invalid, a strategy
is degraded/unreadable, or recoverable value is not liquid. The objective is to recover
assets, establish a valid valuation, and only then fix an immutable cohort recovery ratio.
This document specifies operations; it does not authorize or execute governance transactions.

## 1. Diagnose and preserve evidence

Record the vault, epoch IDs, block number, `grossAssets()`, `totalOwed()`,
`reservedForClaims()`, hot balance, `epochDeficit()` and each epoch's state. Record
`navStatus()`, `warmNavState()`, enabled strategies, their health states, valuation failures
and configured oracle sources. Separate an actual loss from stale or invalid valuation.

| NAV reason | Meaning | Response |
|---|---|---|
| 1 | BufferManager missing | Repair component configuration through governance |
| 2 | Warm NAV invalid | Inspect failing adapters; recover assets before removal |
| 3 | Warm NAV older than 15 minutes | Call permissionless `refreshWarmNav()` and recheck |
| 4 | Strategy/router valuation unavailable | Restore readability or recover and explicitly write down the affected source |
| 5 | Enabled strategy health is not OK, or health query failed | Resolve the health problem or recover and explicitly disable the strategy |
| 6 | Oracle validation failed | Restore the feed or approve a valid configuration change |

Haircut funding attempts a best-effort stale warm-cache refresh and recomputes sizing.
It does not override a failed refresh, invalid adapter, DEGRADED strategy or invalid oracle.
`EpochFundingNavInvalid` leaves the cohort Closed; waiting alone does not repair those
conditions. If legitimate health/readability recovers, valid funding can resume without
removing the strategy.

## 2. Control the funding window

Because `fundEpoch` is permissionless, prevent a partially completed governance recovery
from crystallizing a ratio. Where needed, the vault owner or guardian can set
`pauseEpochCloseFundOnly(true)` before recovery; only the owner can clear it. Record this
action and monitor the funding pause while governance transactions are queued/executed.
An upkeep pause alone cannot stop direct calls to `fundEpoch`.

Restrict new deployments into the affected strategy through the relevant operational
controls. Do not disable its valuation prematurely. Funded claims remain separately
claimable; the funding pause is not the funded-claim breaker. Preserve existing reserves.

## 3. Extract recoverable assets first

1. Establish the recoverable amount and a withdrawal plan for each affected strategy or
   warm adapter. Simulate the authorized transactions against current state.
2. Attempt supported normal recovery/redemption. If normal router guards prevent recovery,
   the router owner may use `emergencyRedeemBatch(plan)` under the governance incident
   process. That path bypasses normal loss-cap, NAV-delta and oracle checks; it is an
   explicit recovery action. Individual withdrawals can fail and be skipped.
3. For warm holdings, use the authorized buffer/refill or adapter recovery path while the
   adapter is still configured. `refreshWarmNav()` only values holdings; it does not move
   cash. `removeWarmAdapter(index)` only removes configuration; it does not withdraw.
4. Verify actual asset receipts in CoreVault, residual holdings and failure events. Do not
   treat a successful batch transaction as proof every strategy was recovered. Reconcile
   balances without spending existing funded reserves.

If extraction cannot recover all value, document the residual, recovery attempts and
loss estimate. Governance must explicitly accept the remaining write-down before funding.

## 4. Repair valuation or recognize the loss

Prefer restoring an accurate, healthy valuation when value remains recoverable. If an
irrecoverable source must be excluded, use the appropriate authorized action:

- **Strategy:** the StrategyRouter owner calls `toggle(strat, false)`. Disabled strategies
  are excluded from safe strategy NAV and `navValidity()`. This does not move their assets.
- **Oracle:** the GlobalConfig governor may set `setVaultOracleOverride(vault, oracle,
  maxStaleness)`, and the router owner controls its secondary oracle configuration.
  Repair the specific failing input; an oracle change does not clear a DEGRADED strategy
  health state or withdraw assets. Do not loosen validation merely to force a haircut.
- **Warm adapter:** the BufferManager owner removes the verified index with
  `removeWarmAdapter(index)` or updates the configured list. Removal is swap-and-pop;
  re-read indices for subsequent removals. Inspect any legacy adapter reference as well
  as the list, then refresh NAV and verify the effective adapter set.

These are separate contracts with their own owner/governor roles. Use the actual configured
Safe/timelock and its required delay; permissionless funding is not governance authority.

**Disabling a strategy that still holds value excludes that value from vault NAV.** Funding
at that point can permanently lock a lower ratio for exiting cohorts. Re-enabling the
strategy or recovering its assets after funding does not top those cohorts up: the recovery
benefits remaining shareholders. This is why extraction precedes disabling/removal.

## 5. Reconcile, then fund

1. Call `refreshWarmNav()` after recovery/configuration changes. Verify `navStatus()` is
   valid and warm NAV is fresh. Record gross assets, liabilities and all funded reserves.
2. Calculate the expected free-asset ratio for each unfunded cohort:
   `min(1, max(0, gross - reserved) / max(0, owed - reserved))`, treating zero free owed as 1.
   Apply contract rounding and confirm the required hot cash is actually available.
3. Have the vault owner clear the close/fund pause only after the valuation and recovery
   decisions are complete. Keep the valuation fresh through execution, especially when
   governance delays exceed the 15-minute cache age limit.
4. Call `fundEpoch`. Confirm `EpochRecoveryCrystallized`, state Funded, recovery index,
   actual reserve, write-down and outstanding counts. A Closed result needs diagnosis;
   it is not a completed write-down. Never bypass the one-base-unit rounding limit.
5. Let required claim automation settle, with manual self-claim available. Monitor reserve
   coverage, failed recipients, LINK balance and settlement completion.

Persist the before/after accounting, configuration changes, approvals and transaction IDs
in the incident record. Monitor later recoveries separately from immutable funded claims.

Sources: `CoreVault.navStatus`, `StrategyRouter.navValidity`, `toggle`,
`emergencyRedeemBatch`, `BufferManager.refreshWarmNav`, `removeWarmAdapter`, and
`EpochedQueueModule.fundEpoch` in this repository.
