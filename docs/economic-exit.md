# Economic Exit at Request

This document defines withdrawal accounting, valuation gates and settlement behavior.

## 1. Request lifecycle

```
request → refresh and validate NAV → price assets owed → transfer fee shares → burn net shares
        → record liability → close settlement epoch → fund and fix recovery index → claim
```

Requests cannot be cancelled. Existing claims do not participate in share-price changes.
Epochs group settlement and do not reprice requests. Instant eligibility selects the fee tier
before the shared pricing helper runs.

## 2. Accounting primitives (single source of truth)

| Primitive | Where | Definition |
|---|---|---|
| `grossAssets()` | `CoreVault.sol` | hot + warm + Σ strategy assets. **The only place they are summed.** |
| `totalOwed()` | `CoreVault.sol` (reads `EpochQueueStorage.totalOwed`) | Unfunded nominal liabilities plus funded reserved liabilities. Increased at request; reduced at funding write-down and settlement. |
| `totalAssets()` | `CoreVault.sol` | `grossAssets() > totalOwed() ? grossAssets() − totalOwed() : 0`. Saturating; never reverts. |
| `liabilityIndex()` | `CoreVault.sol` | `1e18` if `totalOwed == 0 \|\| gross ≥ owed`, else `gross × 1e18 / owed`. Pure function of state, computed on read, not stored. |
| `reservedForClaims` | `EpochQueueStorage` | earmark only. **Not** subtracted from NAV (`totalOwed` already holds everything owed). Every subtraction involving it is saturating. |

**`totalAssets()` lives in the CoreVault shell**, not in a module (it is the ERC-4626 entry point).
The shell is not behind a proxy, so this change requires a **new CoreVault deployment** — see §5.
`test_W15_noModuleReconstructsNavLocally` fails if any module sums the portfolio itself.

## 3. Consumer audit (spec §5)

Class **A** = gross portfolio NAV (`grossAssets()`), class **B** = active shareholder NAV (`totalAssets()`).
Strategy/adapter-internal `totalAssets()` calls (`IStrategy`, `IWarmAdapter`, `StrategyScorer`, the
router's per-strategy NAV probes) read a *strategy's own balance*, not vault NAV, and are out of the
audit's subject; they are listed last for completeness.

### 3.1 Vault shell — `src/core/CoreVault.sol`

| Site | Class | Reads | Note |
|---|---|---|---|
| `totalAssets()` / `_totalAssets()` | B | definition | `max(0, gross − owed)` |
| `grossAssets()` / `_grossAssets()` / `_totalAssetsBreakdown()` | A | definition | only place hot+strat+warm is summed |
| `liabilityState()` / `liabilityIndex()` / `isInsolvent()` | A | `_grossAssets` vs `totalOwed` | the index and the mode are defined here once |
| `totalAssetsBreakdown()` → `nav` | A | `_grossAssets` | consumed by deploy sizing and buffer planning; docs updated: `nav` is **not** net of `totalOwed` |
| `maxDeposit` — `vaultDepositCap` | B | `_totalAssets` | cap on shareholder equity; new depositors buy equity |
| `maxDeposit` — `userDepositCap` | B | `convertToAssets` | shareholder valuation |
| `maxMint`, `previewDeposit`, `previewMint` | B | OZ conversions over `totalAssets()` | deposit/mint pricing |
| `previewWithdraw`, `previewRedeem`, `convertToShares`, `convertToAssets` | B | OZ defaults over `totalAssets()` | never revert on underflow (saturating base) |
| `_depositsAreCurrentlyAllowed` | A | `liabilityState()` | `maxDeposit` is 0 in insolvency and at zero equity (ERC-4626) |
| `canCrystallize` | B | `_totalAssets` | fee is on shareholder performance |
| `canRealize`, `canRealizeWithGap` | A | `_grossAssets` | ops-reserve target vs physical liquidity |
| `_refreshOpsNavCache` / `cachedNavForOps` | **A** | `_grossAssets` | an ops-only cache for keeper/plan decisions; physical value |
| `payRewardShares` (`convertToShares`) | B | | reward payout |

### 3.2 `ERC4626Module`

| Site | Class | Note |
|---|---|---|
| `deposit(…, minShares)` preview, `_depositInternal` (`_previewDeposit`) | B | deposit pricing |
| `mint(…, maxAssets)`, `_mintInternal` (`totalAssets()` × shares) | B | mint pricing |
| `_requireSolvent()` in deposit/mint | A | reverts `VaultInsolvent` |
| `_enforceDepositLimits` — vault cap (`totalAssets()`), user cap (`convertToAssets`) | B | |
| `forceWithdraw` (`previewWithdraw`, `convertToAssets`), fee-event conversions | B | force-exiting holder is a shareholder. Pulls liquidity via `executeRedeemBatch`, which carries the router's `checkOracleFreshness` guard -- **reverts** on a stale oracle. |
| `forceWithdrawAll` (`convertToAssets`, `totalAssets()==0` guard) | B | Pulls liquidity via `forceRedeemForWithdraw`, which has **no oracle check**. `forceWithdrawAll` -- not `forceWithdraw` with a caller-supplied plan -- is the guaranteed exit under a stale oracle. |
| `_notifyIncentivesDeposit` (`convertToAssets`) | B | |
| `_freeLiquidity` | A | hot − `reservedForClaims`, saturating |

### 3.3 `EpochedQueueModule`

| Site | Class | Note |
|---|---|---|
| `_crystallizeExit` — insolvency / zero-equity check (`liabilityState`) | A | |
| `_crystallizeExit` — `convertToAssets(netShares)` | B | **the one pricing call** for a request |
| `_epochCapRemaining(…, _totalAssets())` (`capPerEpochBps`) | B | read **before** the request moves the NAV |
| `_canInstant` — free liquidity | A | hot − reserved, saturating |
| `fundEpoch` — need (`nominal × index`), `reservedForClaims`, hot | A | saturating |
| `claimEpochAssets` / `batchClaimEpochAssets` — index | A | via `liabilityState()` |
| `_crystallize`, `_pps` (perf fee, HWM) | B | crystallisation uses NAV net of `totalOwed` |
| `_updateNavSmooth` | B | |
| `syncInsolvencyState` | A | |

### 3.4 Other modules and periphery

| Site | Class | Note |
|---|---|---|
| `FixedMaturityModule` — funding progress/target/success, `markMatured` snapshot, `fundingFailedPPS`, perf-fee base, `_previewDeposit` | B | `totalOwed == 0` in every state where standard exits are gated, so A ≡ B; B chosen because these are shareholder-capital measures |
| `AdminModule.seedDeadDeposit` (`convertToShares`) | B | |
| `PermitOpsMixin` (`previewWithdraw`) | B | |
| `LiquidityOpsModule` — `canDeploy`, `deployToStrategies` (`totalAssetsBreakdown`) | A | reserve/warm headroom on physical NAV; free hot is net of `reservedForClaims`, saturating |
| `LiquidityOpsModule.realizeForReserveAndOps` | **A** | *changed from `totalAssets()`* → `grossAssets()` |
| `LiquidityOpsModule._buildQueueSafetyContext` | A | queue pressure is `totalOwed` |
| `LiquidityOpsModule._eligibleList` (Σ strategy TVL for rebalance drift) | A | strategy-only TVL, not vault NAV; unchanged |
| `BufferManager.targetHot` | **A** | *changed from `totalAssets()`* |
| `BufferManager.plan` (`totalAssetsBreakdown`, `_reservedForClaims`) | A | reserved subtraction is saturating |
| `StrategyRouter._getCoreNav` (NAV-delta guard on deposit/redeem batches; drives `maxStrategyBps` exposure caps and the loss-cap guards) | **A** | *changed from `totalAssets()`*: a pending-exit liability must not amplify a portfolio delta |
| `StrategyRouter._getAvailableSurplusWithOffset` (ops reserve floor) | **A** | *changed from `totalAssets()`* |
| `VaultUpkeep._gapPassesThreshold` (realize-gap threshold) | **A** | *changed from `totalAssets()`*. Automation is listed out of scope in spec §15, but this one line is a class-A NAV-correctness fix (the realize-gap threshold must compare against the physical portfolio, not shareholder NAV net of `totalOwed`), not new automation behaviour. |
| Circuit-breaker TVL baseline | A | **no call site exists in `src`** (only the `circuitBreakerBps` param, the `CircuitBreakerTriggered` event and `lastTVLSnapshot` storage). Whoever implements it must read `grossAssets()`. |

### 3.5 `CoreVaultLens`

| Site | Class | Note |
|---|---|---|
| `pps`, `previewPPSPostDepositFee`, `previewPPSPostWithdrawFee` | B | |
| `totalAssetsSmooth` | B | |
| `calculateCapImmediateRemaining` | B | must match the module's cap base |
| `getUserReport` (`assetsValue`) | B | plus `pendingClaims` (Σ fixed `assetsOwed`) and `pendingClaimsPayable` (× index) |
| `getVaultReport` | A + B | `totalAssets` (B), `grossAssets`, `totalOwed`, `liabilityIndex`, `insolvent` (A); `pendingWithdrawals == totalOwed` |
| `canRealize` | **A** | mirrors `CoreVault.canRealize` |
| `totalAssetsStrict`, `totalAssetsSafe` | A | **deviation from W-15, deliberate**: independent live recomputations (bypassing the cached warm NAV) used by ops as a cross-check of `grossAssets()`. Diagnostic only; no protocol logic reads them. Compare them against `grossAssets()`, not `totalAssets()`. |

### 3.6 Strategy / adapter-internal reads (not vault NAV)

`StrategyRouter` (per-strategy `totalAssets()` probes for realised-amount and health NAV),
`StrategyScorer`, `BufferManager` (warm adapter `totalAssets()` when refreshing the warm cache),
`AaveV3WarmAdapter_USDC`, `MorphoBlueWarmAdapter_USDC`. These feed `grossAssets()`; none is a NAV consumer.

## 4. Economic exit policy

1. `_crystallizeExit(user, grossShares, mode)` prices once before burning net shares.
   Fees transfer as shares; `assetsOwed` becomes a fixed liability at request time.
2. Instant eligibility is checked after a best-effort warm NAV refresh using the gross
   share value. Eligible requests pay the instant tier; queued fallbacks pay the standard tier.
3. Successful instant exits consume their net payout from the cap. The cap uses
   `capPerEpochBps` and the cap-epoch NAV snapshot; `DynamicCapParams` has no effect.
4. Requests refresh warm NAV, then require `navStatus()` to be valid before pricing.
   Invalid or stale inputs reject the request. Funding requires valid NAV whenever
   crystallization would produce a recovery index below `1e18`; invalid attempts emit
   `EpochFundingNavInvalid` and leave the epoch Closed. Governance can disable an affected
   strategy to explicitly recognize its write-down.
5. Unfunded cohorts use `min(1, (grossAssets - reservedForClaims) /
   (totalOwed - reservedForClaims))`, with saturating subtraction and rounding down.
   Liquidity operations run before the final funding requirement is recomputed.
   Funding locks each cohort's recovery index and writes its haircut out of `totalOwed`.
   Claims use that immutable index. Later recovery accrues to remaining shareholders.
6. Funding and claim shortfalls permit at most one underlying base unit of rounding.
   A larger liquidity deficit keeps the epoch Closed.
7. Standard requests, instant requests, deposit/mint, force exits and funding roll the
   cap epoch before changing assets or supply. A zero cap-epoch duration skips the roll.
   Standard queue activity never consumes the instant cap.

## 5. Deployment plan (new CoreVault)

`totalAssets()` is in the CoreVault shell and the shell is not behind a proxy, so the model change
ships as **a new CoreVault**, not an upgrade. **No deployment until this PR is reviewed and approved.**

Everything bound to the vault address must be redeployed with it, because the class-A consumers
(`BufferManager`, `StrategyRouter`, `VaultUpkeep`) now call `grossAssets()`, which the old vault
does not have, and the old ones would read a net-of-liabilities NAV from the new vault.

1. **Spec §13 — drain the old model first.** On the current vault: close epoch 1, fund it (hot is
   empty: `fundEpoch` realises from the strategy), and let all four pending claims be collected
   under the current model. Verify `outstandingClaimCount == 0` and `reservedForClaims` is dust.
   Two pricing models must never coexist on live claims. The new vault starts with `totalOwed == 0`.
2. **Fix I-10 and confirm the keeper.** `warmNavValid` must be genuinely refreshed; the keeper must call
   `refreshWarmNav()` at least every `MAX_WARM_NAV_AGE` (15 min, and `navRefreshInterval` must stay
   below it). Requests revert `NavStale` otherwise.
3. **Deploy**, through `DeployCoreSystem` / `SelectorLib` (the selector table is the source of truth):
   `CoreVault`, `EpochedQueueModule`, `ERC4626Module`, `LiquidityOpsModule`, `AdminModule`,
   `FixedMaturityModule`, `BufferManager`, `StrategyRouter`, `VaultUpkeep`, `CoreVaultLens`.
   Contract size check: `CoreVault` runtime is 22,137 B (limit 24,576).
4. **Wire and verify** the selectors (`SelectorLib.TOTAL_SELECTORS`), `approveWarmAdapters`,
   the fee params (note deviation 2 for `immediateExitPenaltyBps`), then seal.
5. **Move depositors** with the existing Arbitrum migration tooling (old vault → underlying → new vault).
   Open item: the tooling predates this PR and has not been re-run against it.
6. **Downstream (out of scope here, in this order after approval):** subgraph (`assetsOwed` on
   `ClaimRequest`, drop `ppsAtClose`, add `grossAssets`/`totalOwed`/`liabilityIndex`, new events),
   dapp (fixed amount at request, no cancel, "liquidity available by"), ops console (redefine
   I-2/I-3/I-7, add W-1..W-15, P0 alert on `InsolvencyEntered`), keeper/CRE.
7. **Disclose to depositors** (spec §14, D3/D4): amplified exposure while exits are pending, and
   front-running of a known loss (mitigated by the withdraw fee and the NAV freshness rule).

## 6. Validation

Economic exit acceptance tests cover accounting, immutable cohort indices, free-asset funding,
invalid-NAV funding deferral, cap snapshots, refreshed instant pricing and rounding limits.
Fork tests require the configured archive RPC endpoint.

## 7. Operational checks

Keep NAV inputs fresh. Invalid inputs block new ordinary requests and haircut crystallization.
Monitor `EpochFundingNavInvalid` and `EpochFundingShortfall`. A funded cohort's reserve must
remain available for claims. Recovery after funding accrues to active shareholder equity.

## 8. Settlement and instant-cap guarantees

### 8.1 Request and funding rules

The rules in §4 apply to every ordinary exit. Deposit locks apply to standard and
instant requests; force exits provide the explicit bypass. Instant liquidity uses
hot assets and a warm refill, with a standard queued fallback when unavailable.
Dynamic cap configuration is retained for ABI compatibility and ignored by enforcement
and the lens. Cap snapshots precede changes to assets and supply.

### 8.2 Immutable cohort recovery

Two unfunded cohorts owed 50 each with gross assets of 60 each receive a reserve of 30.
After the first funds, the second is sized from free assets of 30 and unfunded liabilities
of 50, preserving a recovery index of 0.6 without requiring the first cohort to claim.
Each funded cohort retains its index regardless of later asset recovery or claim order.
NAV must be valid before any haircut is crystallized. A transient invalid valuation cannot
transfer value from exiting creditors to remaining shareholders through funding.
