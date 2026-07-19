# Multyr Core — Modules

> **Status**: draft | **Audit-scope**: multyr-core@pierdev
> **Last reviewed by code**: commit `1595a279` on branch `pierdev` (date: 2026-05-15)
> **Version**: 1.0.0-draft

---

## Table of Contents

1. [Overview](#1-overview)
2. [ERC4626Module](#2-erc4626module)
3. [QueueModule](#3-queuemodule)
4. [AdminModule](#4-adminmodule)
5. [BufferManager](#5-buffermanager)
6. [FixedMaturityModule](#6-fixedmaturitymodule)
7. [LiquidityOpsModule](#7-liquidityopsmodule)
8. [FeeCollector](#8-feecollector)
9. [Incentives (v1)](#9-incentives-v1)
10. [IncentivesEngine (v2)](#10-incentivesengine-v2)
11. [BatchGuardrails](#11-batchguardrails)
12. [PriceOracleMiddleware](#12-priceoraclemiddleware)
13. [ExecutionMemory](#13-executionmemory)
14. [StrategyRouter](#14-strategyrouter)
15. [StrategyScorer](#15-strategyscorer)
16. [StrategyHealthRegistry](#16-strategyhealthregistry)
17. [RouterAllocationPolicy V10](#17-routerallocationpolicy-v10)
18. [RouterRebalanceGuard V10](#18-routerrebalanceguard-v10)
19. [Module Interaction Diagram](#19-module-interaction-diagram)
20. [Module Invariant Summary](#20-module-invariant-summary)
21. [Module Deployment and Wiring Reference](#21-module-deployment-and-wiring-reference)

---

## 1. Overview

Multyr Core uses a Diamond-lite architecture where all economic logic is implemented in separate module contracts invoked via `delegatecall` from `CoreVault`. For the routing mechanism see [architecture.md §2](architecture.md#2-diamond-lite-architecture).

**Module execution context**: Every module function that operates via `delegatecall` executes in CoreVault's storage context. `address(this)` equals `CoreVault`. `msg.sender` equals the original caller. `msg.value` is forwarded.

**Module categories**:

| Category | Modules | Deployment pattern |
|---|---|---|
| Delegatecall modules | ERC4626Module, QueueModule, AdminModule, LiquidityOpsModule, FixedMaturityModule | External contracts, invoked via `delegatecall` |
| Standalone modules | BufferManager, FeeCollector, BatchGuardrails, PriceOracleMiddleware, ExecutionMemory | Standard external contracts, external call |
| Strategy infrastructure | StrategyRouter, StrategyHealthRegistry | Standalone external contracts; called by LiquidityOpsModule |
| V10 allocation | StrategyScorer, RouterAllocationPolicy, RouterRebalanceGuard | Standalone view / guard contracts; called by LiquidityOpsModule and StrategyRouter |
| Legacy incentives | Incentives (v1), IncentivesEngine (v2) | External contracts, called via try/catch |

**Security model for delegatecall modules**:
- They access storage ONLY via EIP-7201 namespaced pointers (`CoreStorage.layout()`, `FeeStorage.layout()`, etc.).
- They call back to CoreVault via `address(this).call(...)` for share operations (processor functions).
- They must NOT call arbitrary external contracts without try/catch protection.

---

## 2. ERC4626Module

**File**: `src/core/modules/ERC4626Module.sol`
**Version**: v3 (ExitEngineLib Architecture)
**Delegatecall**: yes (authorized external module for processor functions)
**Storage namespaces**: `CoreStorage`, `FeeStorage`, `FixedMaturityStorage`

### 2.1 Role

Handles all user-facing deposit and force-exit operations. Standard `withdraw()` / `redeem()` always revert — users must use `QueueModule.requestClaim()` for queue-based exits.

### 2.2 Public Functions

| Function | Selector | Access | Description |
|---|---|---|---|
| `deposit(uint256,address)` | `0x6e553f65` | PUBLIC | Deposit assets, receive shares |
| `depositFor(uint256,address)` | `0x36efd16f` | PUBLIC | Deposit on behalf of `receiver`; `msg.sender` is always the payer (router model) |
| `mint(uint256,address)` | `0x94bf804d` | PUBLIC | Mint exact shares, pay gross assets |
| `deposit(uint256,address,uint256)` | `0x0efe6a8b` | PUBLIC | Deposit with min-shares slippage guard |
| `mint(uint256,address,uint256)` | `0x2a1f2a0c` | PUBLIC | Mint with max-assets slippage guard |
| `withdraw(uint256,address,address)` | `0xb460af94` | PUBLIC | **Always reverts** `AsyncWithdrawalRequired` |
| `redeem(uint256,address,address)` | `0xba087652` | PUBLIC | **Always reverts** `AsyncWithdrawalRequired` |
| `withdraw(uint256,address,address,uint256)` | `0x9a0e7d66` | PUBLIC | **Always reverts** `AsyncWithdrawalRequired` |
| `redeem(uint256,address,address,uint256)` | `0xc6e6f592` | PUBLIC | **Always reverts** `AsyncWithdrawalRequired` |
| `forceWithdraw(uint256,address,address,(address,uint256)[],uint256)` | `0x439fdeb4` | PUBLIC | Guaranteed exit with user plan |
| `forceWithdrawAll(address)` | `0x0f0824be` | PUBLIC | Best-effort exit: burns only the proportional slice of shares/fees matching assets actually raised |

Source: `src/core/modules/ERC4626Module.sol:81-332`.

### 2.3 Deposit Flow

```
deposit(assets, receiver):
  1. _checkDepositsAllowed()         — FixedMaturity gate
  2. _notPausedDeposits()            — FLAG_PAUSED / FLAG_PAUSED_DEPOSITS
  3. _enterNonReentrant()            — FLAG_REENTRANCY_LOCKED
  4. _ensureFreshWarmNav()           — auto-refresh, reverts if invalid/stale
  5. _enforceDepositLimits()         — min/vault/user cap checks
  6. feeA = mulBpsDown(assets, depBps)
  7. net = assets - feeA
  8. shares = convertToShares(net)
  9. sharesFee = convertToShares(feeA)
  10. safeTransferFrom(payer → vault, assets)
  11. processorMint(receiver, shares + sharesFee)
  12. processorTransfer(receiver → feeCollector, sharesFee)
  13. emit Deposit, DepositFeeTaken
  14. notifyIncentives (try/catch)
  15. FM auto-close check (if FixedMaturity + Funding + autoClose)
  16. _exitNonReentrant()
```

Source: `src/core/modules/ERC4626Module.sol:457-519`.

### 2.4 forceWithdraw Flow

```
forceWithdraw(assets, receiver, owner_, plan, maxShares):
  1. _checkForceExitAllowed()        — FixedMaturity gate
  2. _notPausedWithdrawals()
  3. _enterNonReentrant()
  4. _trySoftRefreshWarmNav()        — best-effort, never blocks
  5. baseShares = previewWithdraw(assets)
  6. (totalFeeShares, _) = ExitEngineLib.computeFeeShares(baseShares, FORCE, fee)
  7. sharesSpent = baseShares + totalFeeShares
  8. if sharesSpent > maxShares → revert SlippageExceeded
  9. _processorSpendAllowance() if caller != owner
  10. _checkWithdrawalLimitsForForce() — per-tx and per-block limits
  11. _sourceLiquidityForForceWithdraw() — hot → warm → plan execution
  12. processorTransfer(owner → feeCollector, totalFeeShares)
  13. notifyIncentivesExit (try/catch)
  14. processorBurn(owner, baseShares)
  15. safeTransfer(receiver, assets)
  16. emit ForceWithdrawExecuted, ForceExit
```

Source: `src/core/modules/ERC4626Module.sol:163-250`.

### 2.5 Invariants

| ID | Statement |
|---|---|
| M2-I1 | `withdraw()` and `redeem()` NEVER transfer assets (pure revert) |
| M2-I2 | `totalSupply` NEVER increases on any exit (no `_mint` in exit paths) |
| M2-I3 | `forceWithdraw` does NOT consume epoch cap |
| M2-I4 | Fee shares transferred via `processorTransfer` (not mint) — non-dilutive |
| M2-I5 | Deposit rejected if warmNavValid=false or warmNav age > 15 min |

### 2.6 Errors

| Error | Condition |
|---|---|
| `AsyncWithdrawalRequired` | withdraw/redeem always |
| `Paused`, `DepositsPaused`, `WithdrawalsPaused` | Flag checks |
| `NavInvalid` | bufferManager=0 or warmNavValid=false after refresh attempt |
| `NavStale` | warmNav timestamp > 15 min |
| `VaultDepositCapExceeded(after, cap)` | Total NAV + deposit > cap |
| `UserDepositCapExceeded(after, cap)` | User assets + deposit > user cap |
| `SlippageExceeded` | Slippage-protected overloads |
| `EmptyPlan`, `PlanTooLong`, `PlanSumInsufficient` | forceWithdraw plan validation |
| `InsufficientLiquidity` | Plan executed but hot still insufficient |
| `ReentrancyGuardLocked` | Reentrant call detected |

---

## 3. QueueModule

**File**: `src/core/modules/QueueModule.sol`
**Version**: v6 (ExitEngineLib Architecture)
**Delegatecall**: yes
**Storage namespaces**: `CoreStorage`, `QueueStorage`, `FeeStorage`, `FixedMaturityStorage`

### 3.1 Role

Manages the async exit queue: accepts claim requests, processes batch settlements, crystallizes performance fees, and manages epoch rollover.

### 3.2 Public Functions

| Function | Access | Description |
|---|---|---|
| `requestClaim(bool immediate, uint256 shares)` | PUBLIC | Submit exit: instant or queued |
| `cancelClaim(uint256 claimId)` | PUBLIC | Cancel pending queued claim |
| `processQueuedRedemptions(uint256 maxClaims)` | PUBLIC | Process queue (no cap enforcement) |
| `settleFeesAndProcessQueue(uint256 maxClaims)` | PUBLIC | Process queue with epoch cap |
| `endEpochCrystallize()` | PUBLIC | Crystallize perf fee + update NAV smoothing |
| `compactQueue()` | PUBLIC | GC: remove processed head entries from queue array |
| `nextClaimId()` | PUBLIC view | Auto-increment counter |
| `queueLength()` | PUBLIC view | Active queue length (from head to end) |
| `pendingShares()` | PUBLIC view | Total shares in escrow |
| `requiredHotForBatch(uint256 maxClaims)` | PUBLIC view | USDC needed for next settle batch |
| `settlePreview(uint256 maxClaims)` | PUBLIC view | Preview of settle outcome |

Source: `src/core/modules/QueueModule.sol:81-296`.

### 3.3 requestClaim Decision Tree

```
requestClaim(immediate, shares):
  1. _checkStandardExitAllowed()     — FixedMaturity gate
  2. _enterNonReentrant()
  3. rollEpochIfNeeded()             — parametric epoch duration
  4. gross = convertToAssets(shares)
  5. Check minClaimAmount
  6. _checkQueueAntiSpam()           — cooldown + per-epoch count
  7. if (immediate AND _canSettleInstant()):
       INSTANT PATH:
       - computeFeeShares(INSTANT)
       - processorTransfer(user → feeCollector, feeShares)
       - processorBurn(user, userShares)
       - safeTransfer(user, netAssets)
       - consumeEpochCap(gross)
       - emit InstantExit
     else:
       QUEUE PATH:
       - processorTransfer(user → vault, shares)  [escrow]
       - create Claim{user, ts, immediate=false, settled=false, shares}
       - push claimId to queue
       - emit ClaimQueued
```

Source: `src/core/modules/QueueModule.sol:81-169`.

### 3.4 Settlement Algorithm

`_settleScan()` implements a bounded three-step algorithm:

**Step A — Pre-scan** (`_boundedPreScan`):
- Scans up to `maxClaims * 2` queue entries.
- Stops after `MAX_CONSECUTIVE_INELIGIBLE = 32` consecutive ineligible entries.
- Outputs: `requiredHot`, `eligibleCount`, `scanWindowEnd`.

**Step B — Warm refill**:
- If `hot < requiredHot`, attempts `bm.refill(warmGap)` (try/catch).
- Warm refill only — no strategy redeem in settle path.

**Step C — Settle loop** `[head, scanWindowEnd)`:
- Per-claim: escrow invariant check → eligibility check → hot liquidity check → ExitEngineLib fee → settle.
- Pricing: cached `(cachedTA, cachedTS)` snapshot for deterministic intra-batch PPS.
- Head advancement: after loop, head advances past leading settled/ghost entries.

Source: `src/core/modules/QueueModule.sol:358-521`.

### 3.5 Epoch Management

`ExitEngineLib.rollEpochIfNeeded()` is called at the start of `requestClaim`, `processQueuedRedemptions`, and `settleFeesAndProcessQueue`. It aligns `epochStart` to the nearest epoch boundary relative to the original start:

```solidity
// ExitEngineLib.sol:86-91
core.epochStart = uint64(block.timestamp - ((block.timestamp - es) % dur));
core.epochWithdrawn = 0;
```

This ensures epoch boundaries are predictable and monotonically increasing.

### 3.6 Performance Fee Crystallization

`_crystallize()` (`src/core/modules/QueueModule.sol:763-803`):
1. Compute PPS = `totalAssets / totalSupply`.
2. If PPS <= HWM: update HWM, no fee.
3. If PPS > HWM: `profit = totalAssets - HWM * totalSupply`, `feeAssets = profit * perfRateX`.
4. `feeShares = convertToShares(feeAssets)` — minted (dilutive, by design).
5. Update HWM = new PPS post-mint.

Performance fee minting is the ONLY exit-related path that mints new shares (fee accrual is dilutive). All other exits are non-dilutive.

### 3.7 Invariants

| ID | Statement |
|---|---|
| M3-I1 | totalSupply NEVER increases on exit (only decreases via burn) |
| M3-I2 | feeShares transferred via processorTransfer (TRANSFER, not mint) |
| M3-I3 | epochWithdrawn ≤ cap (INSTANT only; STANDARD claims have no cap) |
| M3-I4 | Intra-batch PPS deterministic: all claims in same settleFeesAndProcessQueue use same cachedTA/cachedTS |
| M3-I5 | Queue escrow: vault holds pendingShares; settlement decrements pendingShares on each claim |

### 3.8 Errors

| Error | Condition |
|---|---|
| `ZeroAmount`, `ClaimTooSmall` | Validation on requestClaim |
| `TooManyClaimsThisEpoch` | Anti-spam per-epoch limit exceeded |
| `ClaimCooldownActive` | Anti-spam cooldown active |
| `NotClaimOwner` | cancelClaim: caller != claim.user |
| `AlreadySettled` | cancelClaim on already-settled claim |
| `ReentrancyGuardLocked` | Reentrant requestClaim |

---

## 4. AdminModule

**File**: `src/core/modules/AdminModule.sol`
**Delegatecall**: yes
**Storage namespaces**: `CoreStorage`, `FeeStorage`

### 4.1 Role

All timelock-protected governance functions. Parameter changes go through submit → accept → revoke workflow with `paramMinDelay` enforced ETA.

### 4.2 Timelock Pattern

All mutable params (fees, perf rate, `paramMinDelay`, components) follow:

```
submit*(params):
  - validate params (caps from GlobalConfig)
  - set pending* with eta = block.timestamp + paramMinDelay
  - revert if already pending (must revoke first)

accept*():
  - validate block.timestamp >= eta AND < eta + MAX_WINDOW (7 days)
  - apply params

revoke*():
  - clear pending* (onlyOwner or vetoer)
```

### 4.3 Key Functions

| Function | Role | Timelock | Description |
|---|---|---|---|
| `submitFeeParams(dep,wit,immExit,forceExit,treasury)` | OWNER | yes | Queue fee change |
| `acceptFeeParams()` | OWNER | ETA check | Apply queued fees |
| `revokeFeeParams()` | OWNER/VETOER | — | Cancel pending fees |
| `submitPerfParams(rateX,minInterval)` | OWNER | yes | Queue perf fee change |
| `acceptPerfParams()` | OWNER | ETA check | Apply perf params |
| `submitMinDelay(newDelay)` | OWNER | yes | Queue min delay change |
| `acceptMinDelay()` | OWNER | ETA check | Apply new min delay |
| `setParams(address)` | OWNER | conditionally | Set IParamsProvider (timelock if componentsTl) |
| `setBufferManager(address)` | OWNER | conditionally | Set BufferManager |
| `setRouter(address)` | OWNER | conditionally | Set StrategyRouter |
| `setFeeCollector(address)` | OWNER | — | Update fee recipient |
| `setGuardian(address)` | OWNER | — | Update guardian |
| `setVetoer(address)` | OWNER | — | Update vetoer |
| `enableComponentsTimelock()` | OWNER | — | Enable timelock for setParams/setRouter/setBM |
| `submitBufferManager(address)` | OWNER | yes | Queue BM change (if componentsTl) |
| `acceptBufferManager()` | OWNER | ETA check | Apply queued BM |
| `seedDeadDeposit(uint256)` | OWNER | — | Anti-inflation dead deposit (one-shot) |
| `setInitialFees(...)` | OWNER | — | One-shot fee initialization |
| `setEcosystem(...)` | OWNER | — | Batch-set all component addresses |
| `freezeParams()` | OWNER | — | Permanently freeze paramMinDelay |
| `setRebalancePolicy(address)` | OWNER | — | V10: set allocation policy |
| `setRebalanceGuard(address)` | OWNER | — | V10: set allocation guard |
| `setExecutionMemory(address)` | OWNER | — | V10: set execution memory |
| `getPendingFeeParams()` | PUBLIC view | — | Read pending fee change |
| `getFeeParams()` | PUBLIC view | — | Read active fees |
| `getEcosystem()` | PUBLIC view | — | Read all component addresses |
| `getImmediateExitPenalty()` | PUBLIC view | — | Read immediateExitPenaltyBps |
| `isFeesInitialized()` | PUBLIC view | — | Check fees initialized flag |

Source: `src/core/modules/AdminModule.sol:63-end`, `src/core/libraries/SelectorRegistry.sol:61-109`.

### 4.4 Anti-Governance Attacks

- **H4: Block overwrite of pending params**: `submitFeeParams` reverts with `PendingParamsNotResolved` if `pendingFee.exists` is already true. Owner must revoke before re-submitting. Source: `src/core/modules/AdminModule.sol:82`.
- **ETA window**: accepted params expire after `MAX_WINDOW = 7 days`. After expiry, must revoke and resubmit. Source: `src/core/modules/AdminModule.sol:45`.
- **Max caps**: all fee bps and perf rate are validated against `GlobalConfig` caps (not hardcoded). Caps are governance-configurable but changes require a separate flow via `GlobalConfig`. Source: `src/core/modules/AdminModule.sol:83-87`.

### 4.5 Dead Deposit (Inflation Attack Hardening)

`seedDeadDeposit(uint256 amount)` makes a one-time deposit that mints "dead shares" to a zero address (or dead address). This ensures `totalSupply > 0` from the first real deposit, preventing the ERC-4626 inflation attack. Flag `FLAG_DEAD_DEPOSIT_DONE` is set; subsequent calls revert `DeadDepositAlreadySeeded`.

---

## 5. BufferManager

**File**: `src/core/modules/BufferManager.sol`
**Delegatecall**: NO (standalone external contract, not via delegatecall)
**Called by**: CoreVault directly, VaultUpkeep (keeper)

### 5.1 Role

Manages the hot/warm liquidity buffer around target percentages. The vault holds USDC (hot); warm adapters (Aave, Morpho, etc.) hold additional liquidity for short-term yield and rapid refill.

### 5.2 Key Concepts

**Deploy path**: excess hot funds → warm adapters (keeper-triggered via `rebalance()`).
**Refill path**: warm adapters → vault hot buffer (triggered by settle scan or forceWithdraw).
**NAV cache**: `cachedWarmNav` is updated during `rebalance()`, valid for `navRefreshInterval`.

### 5.3 Public Functions

| Function | Caller | Description |
|---|---|---|
| `rebalance()` | keeper or core | Deploy/withdraw to hit targets + refresh warm NAV cache |
| `refreshWarmNav()` | anyone | Update `cachedWarmNav` without rebalancing |
| `refill(uint256 amount)` | onlyCore | Pull `amount` from warm adapters to vault |
| `forceRefill(uint256 amount)` | onlyCore | Force-pull from warm adapters (best-effort) |
| `warmNavState()` | public view | Returns `(cachedWarmNav, lastWarmNavUpdate, warmNavValid)` |
| `getConfig()` | public view | Returns `BufferConfig` |
| `setConfig(...)` | onlyOwner | Update buffer percentages |
| `addWarmAdapter(address)` | onlyOwner | Register warm adapter |
| `removeWarmAdapter(address)` | onlyOwner | Remove warm adapter |
| `setKeeper(address)` | onlyOwner | Update authorized keeper |

### 5.4 Critical Invariant

**BufferManager must NEVER hold idle USDC**. All assets flow directly between CoreVault (hot) and WarmAdapters. If BM held USDC, `cachedWarmNav` would undercount warm assets, causing share dilution on next deposit. Source: `src/core/modules/BufferManager.sol:16-20`.

### 5.5 WarmNavValid Semantics

`warmNavValid = false` if ANY adapter's `totalAssets()` call fails during `rebalance()` or `refreshWarmNav()`. When `warmNavValid = false`:
- Deposits are blocked (CoreVault `_depositsAreCurrentlyAllowed()` returns false).
- Exits proceed with stale NAV (W2 policy — never block exits).
- `canDeploy()` (LiquidityOpsModule) returns false.

Recovery: keeper calls `rebalance()` → adapter failure → if adapter is removed or fixed, subsequent `rebalance()` call may restore `warmNavValid = true`.

### 5.6 Warm Adapter Diversity

Multiple warm adapters are supported (`_warmAdapters[]` array). On deploy, BM distributes funds across adapters using a primary/fallback strategy. If the primary adapter fails, the fallback is attempted. Source: `src/core/modules/BufferManager.sol:40-43`, events `WarmDeployFallbackUsed`, `WarmDeployAllFailed`.

---

## 6. FixedMaturityModule

**File**: `src/core/modules/FixedMaturityModule.sol`
**Delegatecall**: yes
**Storage namespaces**: `FixedMaturityStorage`, `CoreStorage`, `FeeStorage`

### 6.1 Role

Manages all FixedMaturity vault lifecycle transitions. OpenEnded vaults have zero interaction with this module (gating helpers early-return). For lifecycle state diagram see [architecture.md §9](architecture.md#9-fixed-maturity-lifecycle-states).

### 6.2 Governance Functions (ROLE_OWNER)

| Function | Description | State requirement |
|---|---|---|
| `setVaultModeFixedMaturity()` | Irreversibly switch to FM mode | OpenEnded + routing not frozen |
| `configureFixedMaturity(...)` | One-shot parameter setup | FixedMaturity + Funding + !configured |
| `startFixedMaturityCycle()` | Transition Funding → Starting | FixedMaturity + Funding |
| `activateFixedMaturityCycle()` | Transition Starting → Active | FixedMaturity + Starting |
| `closeFixedMaturityCycle()` | Transition Matured → Closed | Matured + no pending shares |
| `recallFixedTermCapital()` | Recall capital from FM strategy | Active or Matured |

### 6.3 Permissionless Functions (ROLE_PUBLIC)

| Function | Description | Time gate |
|---|---|---|
| `markMatured()` | Trigger Matured state + final perf fee | `block.timestamp >= maturityTs` |
| `markFundingFailed()` | Trigger FundingFailed state | `block.timestamp >= fundingDeadlineTs AND net < min` |
| `refundClaim()` | Claim refund after FundingFailed | FundingFailed state |
| `autoCloseFunding()` | Auto-close Funding on target reached | FixedMaturity + Funding + autoClose enabled |
| `isDepositOpen()` | View: deposits currently open | any |
| `isSettlementOpen()` | View: settlement currently open | any |
| `currentVaultModeAndState()` | View: current mode + state | any |
| `fundingProgressBps()` | View: % of target reached | any |

### 6.4 Final Performance Fee

At `markMatured()`, the final performance fee is applied once:
1. Snapshot `finalPerformanceFeeBaseAssets = totalAssets()` (immutable after this point).
2. Compute fee on principal growth: `profit = totalAssets - fixedTermPrincipalBaseAssets`.
3. Mint fee shares to `feeCollector`.
4. Set `finalPerformanceFeeApplied = true`.

Source: `src/core/modules/FixedMaturityModule.sol`. The `finalPerformanceFeeBaseAssets` snapshot is audit-grade — it captures NAV at the instant of maturity declaration before any fee calculation.

### 6.5 FundingFailed Refund

At `markFundingFailed()`, `fundingFailedPPS` = current PPS is recorded. Each user can call `refundClaim()` to receive assets proportional to their shares at that PPS. This ensures that if the vault never activated, depositors recover their capital at the price they deposited at.

---

## 7. LiquidityOpsModule

**File**: `src/core/modules/LiquidityOpsModule.sol`
**Delegatecall**: yes
**Storage namespaces**: `CoreStorage`, `FixedMaturityStorage`

### 7.1 Role

Handles all strategy capital flows: deploy surplus to strategies, realize assets for queue settlement or reserve maintenance, and rebalance strategy allocations.

### 7.2 Public Functions

| Function | Access | Description |
|---|---|---|
| `canDeploy()` | PUBLIC view | Returns true if surplus deployable |
| `deployToStrategies(uint256 amount)` | PUBLIC | Deploy `amount` to strategies (keeper-triggered) |
| `deployToStrategiesWithPlan(AllocationTypes.AllocPlan)` | ROLE_OWNER_OR_GUARDIAN | Deploy with explicit, caller-supplied allocation plan (V10) |
| `realizeForQueue(uint256 amount)` | PUBLIC | Realize assets from strategies for queue settle |
| `realizeForReserveAndOps(uint256 maxAmount)` | PUBLIC | Realize for hot buffer reserve maintenance |
| `canRebalanceStrategies()` | PUBLIC view | Returns true if rebalance warranted |
| `rebalanceStrategies(...)` | PUBLIC | Rebalance existing strategy allocations |

### 7.3 Deploy Logic

`canDeploy()` checks three conditions (`src/core/modules/LiquidityOpsModule.sol:60-97`):
1. `bufferManager` and `router` are set.
2. Surplus after hot reserve + warm headroom > `minDeployAmount` (from GlobalConfig).
3. At least one enabled strategy exists.

Deploy surplus = `hot - opsReserveTargetBps% - warmHeadroom`.

OpenEnded-only check: `_checkOpenEndedDeployAllowed(fm)` reverts if FixedMaturity vault tries to deploy (capital must flow to `fixedTermStrategy` via FixedMaturityModule, not general router). Source: `src/core/modules/LiquidityOpsModule.sol:18-20`.

### 7.4 V10 Portfolio-Grade Allocation (Optional)

`deployToStrategiesWithPlan()` accepts an externally supplied allocation plan (`plan[i].strat`, `plan[i].amount`) rather than deriving it on-chain, so it is restricted to `ROLE_OWNER_OR_GUARDIAN` — with a caller-supplied plan, a `ROLE_PUBLIC` caller could steer which registered strategies receive capital and in what proportion, even though each `strat` is validated to be enabled (`UnregisteredStrategy` revert otherwise). `deployToStrategies()` remains `ROLE_PUBLIC`/keeper-triggered because its allocation is computed internally, not caller-supplied.

If `rebalancePolicy`, `rebalanceGuard`, and `executionMemory` are set in `CoreStorage`, `deployToStrategiesWithPlan()` and `rebalanceStrategies()` use the portfolio-grade allocation engine:
1. `RouterAllocationPolicy` computes an optimal allocation plan.
2. `RouterRebalanceGuard` validates the plan (NAV delta, adapter caps, oracle freshness).
3. `ExecutionMemory` records outcomes (gas cost, slippage).

`strictExecutionMemory = true` makes execution conditional on ExecutionMemory recording succeeding.

---

## 8. FeeCollector

**File**: `src/core/modules/FeeCollector.sol`
**Delegatecall**: NO (standalone external contract)
**Called by**: CoreVault (processor functions route fees to feeCollector), VaultUpkeep

### 8.1 Role

Receives vault share fees and distributes them to configured sinks: treasury, ops multisig, and safety reserve vault. Handles three share modes:

| ShareMode | Behavior |
|---|---|
| `SPLIT_SHARES` | Split share tokens directly to sinks at their current value |
| `HOLD_TO_TREASURY` | Hold share tokens and send all to treasury on distribution |
| `AUTO_HARVEST` | Call `requestClaim(true, shares)` on the vault to convert to USDC before distributing |

### 8.2 AUTO_HARVEST Mode

In `AUTO_HARVEST` mode, `FeeCollector` calls `IQueueModule.requestClaim(true, bal)` on the vault to convert shares to USDC. If the instant exit falls back to queue (epoch cap exhausted), `pendingHarvestShares[token]` is incremented. A subsequent `harvestQueued()` call checks for settled shares and credits the remaining USDC.

Source: `src/core/modules/FeeCollector.sol:55-58`.

### 8.3 Distribution

`distribute(address token)` splits the token balance among three sinks:
- **Treasury** (`treasuryBps` bps): protocol treasury.
- **Ops** (remainder up to `OPS_MAX_BPS`): operations multisig.
- **Safety reserve** (`safetyReserveBps` bps): safety reserve vault.

Fee provenance is tracked per-vault via `vaultFeeAccumulated[vault]`. Source: `src/core/modules/FeeCollector.sol:34`.

### 8.4 Governor and Allowlist

`FeeCollector` has an immutable `governor` (timelock/multisig executor) for parameter changes. An allowlist of accepted tokens can be toggled (`allowlistEnabled`). Distribution below `minDistribution[token]` is a no-op.

---

## 9. Incentives (v1)

**File**: `src/core/modules/Incentives.sol`
**Delegatecall**: NO (external call with try/catch)

### 9.1 Role

Legacy incentives hook. Called by `ERC4626Module` on deposit and exit with try/catch (W2: never blocks operations). Notifies the incentives contract of balance changes so it can update user reward accrual.

### 9.2 Interface

```solidity
interface IIncentives {
    function onDeposit(address user, uint256 netUsdc18, uint256 totalUsdc18) external;
    function onExit(address user, uint256 netUsdc18) external;
}
```

Called with values scaled to 18 decimals regardless of USDC's 6-decimal precision (`net * 1e12`). Source: `src/core/modules/ERC4626Module.sol:741-756`.

### 9.3 Deprecation Note

`IIncentives` (v1) is superseded by `IIncentivesEngine` (v2). Both may coexist during migration. The v1 interface is retained for backward compatibility and is called only if `core.incentives != address(0)`.

---

## 10. IncentivesEngine (v2)

**File**: `src/core/modules/IncentivesEngine.sol`
**Delegatecall**: NO (external call with try/catch)

### 10.1 Role

Tranche-based incentives engine. Tracks user participation across configurable tranches with entry/exit events. Supports more complex reward accrual rules than v1.

### 10.2 Interface

```solidity
interface IIncentivesEngine {
    function onDeposit(address user, uint256 netUsdc18) external;
    function onExit(address user, uint256 assetsExited18) external;
    function onExitLight(address user, uint256 assetsExited18) external; // gas-efficient
}
```

`onExitLight()` is called in the queue settle path (gas-constrained). Source: `src/core/modules/QueueModule.sol:644-651`.

### 10.3 Error Handling

All IncentivesEngine calls are wrapped in try/catch. A failure does NOT block the corresponding deposit or exit operation. This maintains the W2 policy (never block exits) and also ensures deposit failures (rare misconfiguration) don't lock users out.

---

## 11. BatchGuardrails

**File**: `src/core/modules/BatchGuardrails.sol`
**Delegatecall**: NO (standalone validator)

### 11.1 Role

Pre-execution validator for batch strategy operations. Used by `RouterRebalanceGuard` (V10 allocation engine) to validate allocation plans before execution. All addresses are `immutable` — contract is vault-specific and stateless beyond configuration.

### 11.2 Guardrails Enforced

| Guardrail | Check |
|---|---|
| Max actions per batch | `count <= Config.maxActionsPerBatch()` |
| Cooldown | `elapsed >= Config.rebalanceCooldown()` |
| NAV delta | `|newNAV - oldNAV| / oldNAV * BPS <= Config.maxNavDeltaBps()` |
| Adapter allowlist | `Config.isAdapterAllowed(adapter)` for each leg |
| Adapter caps | `allocation <= Config.adapterCap(adapter)` |
| Oracle freshness | `PriceOracleMiddleware.isPriceFresh(asset)` |

Source: `src/core/modules/BatchGuardrails.sol:20-56`.

### 11.3 Usage

`BatchGuardrails` is constructed with immutable `config`, `oracle`, and `vault` addresses. It is NOT a module in the module-routing sense — it is called externally by `RouterRebalanceGuard` or directly by keepers for pre-flight validation.

---

## 12. PriceOracleMiddleware

**File**: `src/core/modules/PriceOracleMiddleware.sol`
**Delegatecall**: NO (standalone external contract)

### 12.1 Role

Abstraction layer over price oracles (Chainlink, Pyth, custom). Provides a unified interface for price queries with staleness protection. Used by `BatchGuardrails` for oracle freshness checks.

### 12.2 Key Properties

- **Oracle staleness**: heartbeat-based validity (configurable per-asset, default 86400s = 24h for Chainlink).
- **Fallback**: configurable primary/secondary oracle per asset.
- **Admin**: set by owner; oracle addresses are updatable.

### 12.3 Interface

```solidity
interface IPriceOracleMiddleware {
    function isPriceFresh(address asset) external view returns (bool);
    function getPrice(address asset) external view returns (uint256 price, bool fresh);
}
```

---

## 13. ExecutionMemory

**File**: `src/core/modules/ExecutionMemory.sol`
**Delegatecall**: NO (standalone external contract)

### 13.1 Role

Records per-strategy execution outcomes for the V10 portfolio-grade allocation engine. Maintains exponential moving averages (EMA) of gas cost and slippage per strategy. Used by `RouterAllocationPolicy` to compute optimal allocation plans.

### 13.2 Key Storage

```solidity
// ExecutionMemory.sol:17-26
struct ExecRec {
    uint64 emaGasCost;           // EMA of gas cost (USD, 6 decimals)
    uint32 emaSlippageBps;       // EMA of slippage in bps
    uint32 failedCount;          // Total failed executions
    uint32 successCount;         // Total successful executions
    int32  emaRealizedVsExpectedBps; // EMA of realized vs expected return deviation
    uint64 lastUpdateTs;         // Timestamp of last update
    uint16 observationCount;     // Total observations (bootstrap threshold)
}
mapping(address => ExecRec) _records;
```

### 13.3 Bootstrap Safety (Correction #3)

Before `minObservationsForLiveCost` (default: 10) and `minObservationsForPenalty` (default: 20) observations are collected:
- `gasCost` returns `fallbackGasCostUsd = 50 USDC`
- `slippageBps` returns `fallbackSlippageBps = 5`
- `penaltyBps` returns `fallbackPenaltyBps = 50`

This prevents the allocation engine from making extreme decisions based on too few data points.

### 13.4 Inactivity Decay (Improvement #4)

If a strategy has not been executed for `inactivityDecayThresholdSeconds` (default: 30 days), its historical statistics are blended toward fallback values using `inactivityDecayBetaBps` (default: 50%). This prevents stale historical data from artificially favoring inactive strategies.

Source: `src/core/modules/ExecutionMemory.sol:50-51`.

---

## 14. StrategyRouter

**File**: `src/core/modules/StrategyRouter.sol`
**Lines**: 1164
**Deployment**: Standalone (NOT delegatecall). Called by `LiquidityOpsModule` via standard external call.
**Access**: `onlyCore` for batch operations, `onlyOwner` for emergency / governance operations.

### 14.1 Role

`StrategyRouter` is the single entry point for all capital movements between `CoreVault` and registered yield strategies. It enforces guardrail checks (cooldown, NAV delta, oracle freshness, adapter allowlist), applies per-strategy and aggregate loss caps, and dispatches across three intake modes: PRIORITY, WEIGHTED, and SCORED.

### 14.2 Key State

| Variable | Type | Default | Description |
|---|---|---|---|
| `core` | `address` | constructor | CoreVault address — `onlyCore` guard |
| `owner` | `address` | constructor | Timelock / Safe |
| `intakeMode` | `IntakeMode` | `PRIORITY` | Allocation mode for deposits and redemptions |
| `lossCapBps` | `uint16` | `50` (0.5%) | Aggregate loss cap across all strategies in one batch |
| `lossCapPerStrategy` | `mapping(address→uint16)` | 0 | Per-strategy loss cap; 0 = no cap |
| `maxStrategyBps` | `mapping(address→uint16)` | 0 | Max allocation fraction per strategy; 0 = no cap |
| `gasPerStrategyWithdraw` | `uint256` | `100_000` | Gas reserved per strategy in `planRedeem` gas-adaptive sizing |
| `MAX_DEPOSIT_LEGS` | `uint256` | `12` | Hard limit on deposit plan length |
| `secondaryOracle` | `address` | 0 | Optional secondary oracle for deviation cross-check |
| `healthRegistry` | `IStrategyHealthRegistry` | 0 | Optional health registry; absence = all strategies treated as healthy |
| `scorer` | `IStrategyScorerV10` | 0 | Optional scorer used in SCORED intake mode |

Source: `src/core/modules/StrategyRouter.sol:38-76`.

### 14.3 Intake Modes

| Mode | Deposit behaviour | Redeem behaviour |
|---|---|---|
| `PRIORITY` | Deposits to strategies in registered priority order | Drains highest-priority enabled strategies first |
| `WEIGHTED` | Plan built off-chain; router executes best-effort | Proportional withdrawal weighted by each strategy's `totalAssets()` share |
| `SCORED` | Off-chain scoring via `StrategyScorer`; router executes pre-built plan | Falls back to PRIORITY ordering |

### 14.4 Guardrail Modifiers

All paths through `executeDepositBatch` and `executeRedeemBatch` pass through stacked modifiers evaluated before any state change:

| Modifier | Purpose |
|---|---|
| `checkCooldown` | Minimum time between consecutive batches (`params.batchCooldownSeconds()`) |
| `checkBatchSize(n)` | Rejects batches exceeding `MAX_DEPOSIT_LEGS` |
| `checkAdapterAllowlist(addrs[])` | Rejects any strategy address not registered via `register()` |
| `checkNavDelta` | Reverts post-execution if `|navAfter − navBefore| / navBefore > params.maxNavDeltaBps()` |
| `checkOracleFreshness` | Triple-check: (1) `isFresh` flag on params, (2) timestamp not in the future, (3) age ≤ `maxStaleSeconds` |

Source: `src/core/modules/StrategyRouter.sol:235-380`.

### 14.5 Public Functions

| Function | Access | Description |
|---|---|---|
| `register(address)` | `onlyOwner` | Register strategy; validates `strategy.asset() == core.asset()` |
| `toggle(address,bool)` | `onlyOwner` | Enable / disable a registered strategy |
| `setIntakeMode(IntakeMode)` | `onlyOwner` | Switch PRIORITY / WEIGHTED / SCORED |
| `setLossCap(uint16)` | `onlyOwner` | Set aggregate loss cap in bps |
| `setLossCapPerStrategy(address,uint16)` | `onlyOwner` | Set per-strategy loss cap |
| `setMaxStrategyBps(address,uint16)` | `onlyOwner` | Set per-strategy max allocation fraction |
| `executeDepositBatch(Allocation[])` | `onlyCore` | Best-effort deposit batch with all guardrails |
| `planRedeem(uint256)` | `view` | Compute optimal `Pull[]` plan for a target withdrawal amount |
| `executeRedeemBatch(Pull[])` | `onlyCore` | Best-effort redeem batch with loss cap and NAV delta checks |
| `harvest(uint256)` | `onlyCore` | Batch harvest with per-strategy try/catch; emits `HarvestBatchSummary` |
| `emergencyRedeemBatch(Pull[])` | `onlyOwner` | Emergency exit: bypasses lossCap, navDelta, cooldown, oracle checks |
| `forceRedeemForWithdraw(uint256)` | `onlyCore` | Greedy extraction sorted by available liquidity; no loss cap (W2 policy) |
| `withdrawAllToCore(address)` | `onlyOwner` | Calls `IStrategy.withdrawAll(core)` on a single strategy |
| `totalStrategyAssetsSafe()` | `view` | Gas-capped staticcall across all enabled strategies; never reverts |

Source: `src/core/modules/StrategyRouter.sol:390-1164`.

### 14.6 Key Invariants

- `planSum ≤ availableSurplus` before any deposit transfer — `planSum > available` reverts with `InvalidPlanSum` (`src/core/modules/StrategyRouter.sol:679-680`).
- Per-strategy allocation cap uses the `navBefore` snapshot (not live NAV inside the loop), preventing double-counting when `fundsAlreadyTransferred=true` (`src/core/modules/StrategyRouter.sol:712`).
- `emergencyRedeemBatch` and `forceRedeemForWithdraw` intentionally bypass loss cap — W2 policy: forced exit must never be blocked by loss accounting.
- `_isHealthy` is FAIL-CLOSED: if `healthRegistry.isHealthyForDeposit()` reverts, the strategy is excluded from the batch (`src/core/modules/StrategyRouter.sol:992-996`).

---

## 15. StrategyScorer

**File**: `src/core/modules/StrategyScorer.sol`
**Lines**: 826
**Deployment**: Standalone view contract. Implements `IStrategyScorerV10`.
**Version**: V10 (EMA, confidence, capital buckets, execution quality multiplier).

### 15.1 Role

`StrategyScorer` scores yield strategies across five dimensions and produces proportional capital allocations. It is called by `RouterAllocationPolicy.buildRebalancePlan()` and by `StrategyRouter` in SCORED intake mode. All keeper pokes are the only state mutations; all scoring logic is view-only.

### 15.2 Scoring Formula

```
rawScore(s) = wAPY    × apyNorm(s)
            + wLiq    × effectiveLiq(s)
            + wRisk   × effectiveRisk(s)
            + wStability × effectiveStability(s)
            + wIncentive × decayedIncentive(s)

finalScore(s) = rawScore(s) × _executionQualityMultiplierBps(s) / 1e4
```

Default weights (must sum to exactly 10 000):

| Weight | Default | Dimension |
|---|---|---|
| `wAPY` | 4 000 (40%) | Annualized yield |
| `wLiq` | 1 500 (15%) | Liquidity depth |
| `wRisk` | 2 500 (25%) | Risk (inverted: low risk → high contribution) |
| `wStability` | 1 000 (10%) | Historical NAV stability |
| `wIncentive` | 1 000 (10%) | Decaying incentive bonus |

Source: `src/core/modules/StrategyScorer.sol:33-45`.

### 15.3 V10 Extensions

| Feature | Description |
|---|---|
| **Time-aware EMA** | Bucketed alpha by Δt since last poke: <6 h → 10%, <1 d → 25%, <3 d → 40%, ≥3 d → 60%; long-gap (> `maxEmaGap`) reseeds from spot (`src/core/modules/StrategyScorer.sol:661-701`) |
| **APY volatility tracking** | EMA of `|spot − prevEma|` with α=20%; stored in `apyVolatilityBps`; used by `riskAdjustedAPY()` (`src/core/modules/StrategyScorer.sol:694-696`) |
| **Confidence** | Per-strategy `confidenceBps`; source-validity flag; stale decay: age > 1× → halved, age > 2× → clamped to `staleConfidenceFloorBps`; missing source → `defaultConfidenceBps` (`src/core/modules/StrategyScorer.sol:724-735`) |
| **Capital buckets** | 0 = CORE, 1 = TACTICAL; TACTICAL bucket zeroes allocation when confidence < `minConfidenceForAllocationBps` (`src/core/modules/StrategyScorer.sol:601-622`) |
| **Risk-adjusted APY** | `riskAdjustedAPY = emaApy − volPenaltyBps − illiqPenaltyBps − opRiskBps` (`src/core/modules/StrategyScorer.sol:713-722`) |

### 15.4 Staleness Floors

When a signal is stale (age > `staleness_seconds`), its score is halved and clamped to a floor:

| Signal | Floor constant | Value |
|---|---|---|
| Risk | `STALE_RISK_FLOOR_BPS` | 4 000 |
| Stability | `STALE_STABILITY_FLOOR_BPS` | 3 000 |
| Liquidity | `STALE_LIQ_FLOOR_BPS` | 2 000 |

Source: `src/core/modules/StrategyScorer.sol:20-24`.

### 15.5 Key Functions

| Function | Access | Description |
|---|---|---|
| `computeScores(strategies[],tvl)` | `view` | 2-pass: collect maxAPY for normalization, then score + normalize to sum 10 000 |
| `computeAllocations(strategies[],tvl)` | `view` | Calls `computeScores` then proportional allocation with absolute and relative caps |
| `shouldRebalance(strategies[],currentAllocs[],tvl)` | `view` | Returns `true` if total drift ≥ `rebalanceMinMoveBps` |
| `isEligible(strategy)` | `view` | FAIL-CLOSED: `false` if `healthRegistry.isHealthyForDeposit` reverts |
| `effectiveConfidence(strategy)` | `view` | Source-valid, staleness-adjusted confidence bps |
| `riskAdjustedAPY(strategy)` | `view` | EMA APY minus penalty signals |
| `emaState(strategy)` | `view` | Returns `(lastUpdateTs, emaApyBps, apyVolatilityBps)` |
| `pokeStrategyMetrics(strategy,apy,liq,stab,conf)` | `onlyKeeper` | Single-call batch poke for all signals + EMA update |

Source: `src/core/modules/StrategyScorer.sol:86-266`.

### 15.6 Key Invariants

- `setScoringWeights` reverts with `WeightsSumInvalid` if weights do not sum to exactly 10 000 (`src/core/modules/StrategyScorer.sol:387-394`).
- `MAX_STRATEGIES = 10` bounds `computeScores` iteration — safe for on-chain execution.
- Score normalization falls back to quality-weighted equal share when all raw scores are zero (`src/core/modules/StrategyScorer.sol:502-525`).
- TACTICAL strategies below confidence threshold receive `allocationMultiplierBps = 0`, fully zeroing their allocation (`src/core/modules/StrategyScorer.sol:605-607`).

---

## 16. StrategyHealthRegistry

**File**: `src/core/modules/StrategyHealthRegistry.sol`
**Lines**: 185
**Deployment**: Standalone. Implements `IStrategyHealthRegistry`.

### 16.1 Role

`StrategyHealthRegistry` is the guardian-controlled state machine tracking health status for each registered strategy. It is the FAIL-CLOSED gate consulted by `StrategyRouter` before deposits and by `StrategyScorer.isEligible()`.

### 16.2 Health States

| State | Value | Deposit eligible |
|---|---|---|
| `OK` | 0 | Yes |
| `DEGRADED` | 1 | No |
| `BROKEN` | 2 | No |

`isHealthyForDeposit(address)` returns `true` only when state is `OK`.

### 16.3 Access Control

| Role | Authority | Permitted transitions |
|---|---|---|
| `owner` | Constructor; Timelock/Safe | OK, DEGRADED, BROKEN |
| `guardian` | Constructor; hot EOA | DEGRADED, BROKEN only (`GuardianCannotMarkOK`) |
| `authorizedCallers` | Added by owner | NAV updates only (`updateLastKnownNAV`) |

The guardian restriction enforces that recovery to `OK` always requires owner (Timelock) action — a guardian can quarantine but cannot unquarantine. Source: `src/core/modules/StrategyHealthRegistry.sol:36` (error declaration), `src/core/modules/StrategyHealthRegistry.sol:115` (revert in `setHealthy`), `src/core/modules/StrategyHealthRegistry.sol:140` (revert in `markHealthy`).

### 16.4 Key Functions

| Function | Access | Description |
|---|---|---|
| `setStrategyState(address,StrategyState,string)` | `onlyOwnerOrGuardian` | Set health state with reason string |
| `batchSetStrategyState(address[],StrategyState[],string[])` | `onlyOwnerOrGuardian` | Batch version |
| `updateLastKnownNAV(address,uint256)` | `onlyAuthorizedCaller` | Cache last known NAV (called post-deposit/redeem by `StrategyRouter`) |
| `isHealthyForDeposit(address)` | `view` | Returns `state == OK` |
| `getStrategyState(address)` | `view` | Returns raw `StrategyState` enum value |
| `getStrategyHealth(address)` | `view` | Returns full `StrategyHealth` struct (state + lastKnownNAV + reason) |

Source: `src/core/modules/StrategyHealthRegistry.sol:95-185`.

### 16.5 Key Invariants

- Guardian cannot set `OK` — `GuardianCannotMarkOK` is a hard revert (`src/core/modules/StrategyHealthRegistry.sol:36,115,140`).
- Absence of registry (`address(0)`) in `StrategyRouter` defaults to all strategies healthy — permissive path for bootstrap phase.

---

## 17. RouterAllocationPolicy V10

**File**: `src/core/modules/RouterAllocationPolicy.sol`
**Lines**: 448
**Deployment**: Standalone view contract. Called by `LiquidityOpsModule`.

### 17.1 Role

`RouterAllocationPolicy` builds deterministic `RebalancePlan` structs from current allocations and scorer targets. It applies regime-aware core/tactical bucket constraints and classifies plans as normal or safety using `AllocationInvariantLib.isSafetyCondition`.

### 17.2 buildRebalancePlan Pipeline

`buildRebalancePlan(strategies[], currentAllocs[], tvl)` executes 8 steps:

1. Sort strategies ascending by address (insertion sort, deterministic, N ≤ 10).
2. Compute target allocations via `scorer.computeAllocations()`.
3. Apply regime-aware bucket constraints (CORE min/max, TACTICAL remainder).
4. Compute per-strategy `withdrawAmounts` and `depositAmounts` as signed deltas.
5. Compute `driftBps = totalMoveUsd / tvl × 10 000`.
6. Compute `weightedCurrentAPYBps` and `weightedTargetAPYBps` (risk-adjusted EMA APY, allocation-weighted).
7. Compute `aggregateConfidence` (allocation-weighted average of per-strategy confidence).
8. Classify safety via `AllocationInvariantLib.isSafetyCondition`.

Source: `src/core/modules/RouterAllocationPolicy.sol:44-163`.

### 17.3 Regime-Aware Bucket Constraints

| Regime | Core min | Core max |
|---|---|---|
| 0 — STABLE | 80% | 90% |
| 1 — VOLATILE | 75% | 85% |
| 2 — STRESS | 90% | 95% |

`currentRegime()` reads from `RouterRebalanceGuard.currentRegime()` via low-level staticcall to avoid circular import. Source: `src/core/modules/RouterAllocationPolicy.sol:187-194`.

### 17.4 Safety Classification

`classifySafety()` calls `AllocationInvariantLib.isSafetyCondition` with default thresholds:

| Parameter | Default |
|---|---|
| `healthThresholdBps` | 7 000 |
| `liquidityReadinessThresholdBps` | 3 000 |
| `maxStrategyExposureBps` | 4 000 |
| `queuePressureThresholdBps` | 3 000 |

A plan flagged as safety bypasses most gate checks in `RouterRebalanceGuard` (see §18). Source: `src/core/modules/RouterAllocationPolicy.sol:350-398`.

### 17.5 Key Invariants

- Sort is deterministic ascending address — strategies in any input order produce an identical plan.
- Bucket redistribution preserves total TVL allocation (proportional scale-up/scale-down).
- `classifySafety` view uses `queuePressureBps = 0` (no queue state accessible in view context); the guard enforces queue safety separately.

---

## 18. RouterRebalanceGuard V10

**File**: `src/core/modules/RouterRebalanceGuard.sol`
**Lines**: 591
**Deployment**: Standalone. Single source of decision for whether a rebalance proceeds.

### 18.1 Role

`RouterRebalanceGuard` is the portfolio-grade gate that decides whether a `RebalancePlan` may proceed. It applies hysteresis, minimum move thresholds, benefit/cost analysis, budget limits, and safety exceptions. The result is a `PlanEvaluation` struct containing the (possibly scaled) plan and a `GuardReason` code.

### 18.2 Three Regimes

| Regime | Hysteresis mult | Budget mult | Horizon days | Confidence mult |
|---|---|---|---|---|
| 0 — STABLE | 100% | 100% | 30 | 100% |
| 1 — VOLATILE | 150% | 70% | 14 | 80% |
| 2 — STRESS | 200% | 30% | 7 | 50% |

Keeper or owner can switch regime with `setRegime()`; owner can force with `forceRegime()`. Source: `src/core/modules/RouterRebalanceGuard.sol:126-155`.

### 18.3 evaluatePlan Pipeline (9 steps)

| Step | Check | Safety plan override |
|---|---|---|
| 1 | Plan validity (non-empty strategies, tvl > 0) | None |
| 2 | STRESS regime block (non-safety plans) | Safety plans pass |
| 3 | Queue safety (pressure threshold + idle after plan) | Safety plans skip |
| 4 | Hysteresis (entry/exit drift thresholds; consecutive-skip relaxation) | Safety plans skip |
| 5 | Minimum move (`max(minMoveUsd, tvl × minMoveBps)`) | Safety plans skip |
| 6 | Benefit / cost (net benefit ≥ `minNetBenefitBps`; ratio ≥ `minBenefitCostRatioBps`) | Safety plans skip |
| 7 | Budget → compute `allowedMoveBps` (regime-scaled; safety uses `safetyMaxMoveBpsPerDay`) | Higher budget cap |
| 8 | Scale plan (`AllocationInvariantLib.scalePlan`) when `driftBps > allowedMoveBps` | None |
| 9 | Post-scale re-evaluation of minimum move and net benefit | Safety plans skip |

Source: `src/core/modules/RouterRebalanceGuard.sol:162-296`.

### 18.4 Budget Model

| Parameter | Default | Description |
|---|---|---|
| `maxMoveBpsPerCycle` | 1 000 (10%) | Cap per single rebalance call |
| `maxMoveBpsPerDay` | 2 000 (20%) | Daily cumulative cap (normal plans) |
| `safetyMaxMoveBpsPerDay` | 5 000 (50%) | Daily cumulative cap (safety plans) |
| `budgetMode` | `HARD_RESET` | Hard reset vs rolling decay at interval |
| `budgetResetIntervalSeconds` | 86 400 | Reset / decay period |

`consumeBudget(movedBps)` and `notifySkip()` are called by the orchestrator (`LiquidityOpsModule`) after execution. Source: `src/core/modules/RouterRebalanceGuard.sol:437-467`.

### 18.5 Consecutive-Skip Relaxation (Improvement #5)

After `maxConsecutiveSkips` (default: 5) consecutive skips, hysteresis thresholds are multiplied by `skipRelaxMultBps` (default: 70%), lowering the barrier to the next rebalance. Counter resets to zero on successful `consumeBudget`. Source: `src/core/modules/RouterRebalanceGuard.sol:199-213`.

### 18.6 Key Invariants

- In STRESS regime, all non-safety plans return `STRESS_BLOCK` — no capital movement unless flagged safety (`src/core/modules/RouterRebalanceGuard.sol:177-179`).
- Benefit formula uses `AllocationInvariantLib.computeNetBenefitBps` — single formula eliminates dual-path inconsistency (Fix #2).
- Plan scaling uses `AllocationInvariantLib.scalePlan` with formal derivation (Fix #3).
- `consumeBudget` and `notifySkip` are `onlyOrchestrator` — keeper cannot manipulate budget state directly.

---

## 19. Module Interaction Diagram

```mermaid
graph LR
    CV["CoreVault"]
    EM["ERC4626Module"]
    QM["QueueModule"]
    AM["AdminModule"]
    LOM["LiquidityOpsModule"]
    FM["FixedMaturityModule"]
    BM["BufferManager"]
    FC["FeeCollector"]
    SR["StrategyRouter"]
    INC["Incentives (v1)"]
    IE["IncentivesEngine (v2)"]
    EE["ExecutionMemory"]
    RAP["RouterAllocationPolicy"]
    RRG["RouterRebalanceGuard"]
    BG["BatchGuardrails"]
    POM["PriceOracleMiddleware"]

    CV -->|delegatecall| EM
    CV -->|delegatecall| QM
    CV -->|delegatecall| AM
    CV -->|delegatecall| LOM
    CV -->|delegatecall| FM

    EM -->|processorMint/Burn/Transfer| CV
    QM -->|processorTransfer/Burn| CV
    AM -->|reads/writes CoreStorage, FeeStorage| CV

    EM -->|try/catch| INC
    EM -->|try/catch| IE
    QM -->|try/catch| IE

    EM -->|safeTransfer| BM
    QM -->|refill| BM

    LOM -->|executeDepositBatch| SR
    LOM -->|query scorer| SR
    LOM -->|allocPlan| RAP
    LOM -->|validatePlan| RRG
    LOM -->|recordExecution| EE

    RRG -->|validateBatch| BG
    BG -->|isPriceFresh| POM

    CV -->|safeTransfer shares to| FC
    FC -->|requestClaim(true)| CV

    SR -->|totalStrategyAssetsSafe| CV
```

---

## 20. Module Invariant Summary

| Module | Key Invariants |
|---|---|
| ERC4626Module | withdraw/redeem always revert; no mint on exit; deposit blocked if warmNavInvalid |
| QueueModule | totalSupply decreases only on exit; batch PPS deterministic; escrow balance ≥ pendingClaim.shares |
| AdminModule | Pending params must be resolved before new submission; ETA window 7 days; fee caps enforced |
| BufferManager | Never holds idle USDC; cachedWarmNav reflects 100% of warm assets |
| FixedMaturityModule | finalPerformanceFeeApplied exactly once; fundingFailedPPS immutable after markFundingFailed |
| LiquidityOpsModule | OpenEnded-only deploy path; surplus calculation = hot - reserve - warm headroom |
| FeeCollector | AUTO_HARVEST tracks pendingHarvestShares on queue fallback; governor is immutable |
| ExecutionMemory | Bootstrap fallbacks below observation threshold; inactivity decay after 30 days |

---

## 21. Module Deployment and Wiring Reference

When deploying a new vault or replacing a module, the following registration sequence must be followed:

### 16.1 Initial Module Registration

```solidity
// Step 1 — register each module selector
vault.setModule(selector, moduleAddress, requiredRole);

// Step 2 — authorize module for processorMint/Burn/Transfer (if needed)
vault.setAuthorizedModule(moduleAddress, true);

// Step 3 — (optional) set SelectorRegistry before first routing freeze
vault.setSelectorRegistry(registryAddress);

// Step 4 — freeze routing (irreversible; requires FLAG_ROUTING_FROZEN=false)
vault.freezeRouting();
```

For the bootstrap deployment, `paramMinDelay = 0` allows instant parameter acceptance. Governance should raise `paramMinDelay` to ≥2 days via `submitParamMinDelay` + `acceptParamMinDelay` before any TVL is committed. Source: `src/core/modules/AdminModule.sol:280-310`.

### 16.2 Module Replacement (Upgrade Path)

Module addresses are mutable until routing is frozen. The recommended upgrade workflow:

1. Deploy new module contract.
2. Call `vault.setModulesBatch(selectors[], newAddresses[], roles[])` — atomically updates all selectors belonging to the module.
3. Call `vault.setAuthorizedModule(oldModule, false)` and `vault.setAuthorizedModule(newModule, true)` if the module uses `processorMint/Burn/Transfer`.
4. Smoke-test all upgraded selectors via a read-only call.
5. If a `paramMinDelay > 0` governs module changes, step 2 must go through the timelock submit/accept cycle in AdminModule.

Source: `src/core/CoreVault.sol:263-309`.

### 16.3 BatchGuardrails and PriceOracleMiddleware Registration

`BatchGuardrails` and `PriceOracleMiddleware` are NOT registered as CoreVault modules (no delegatecall). They are independent contracts called directly by `RouterRebalanceGuard` and `LiquidityOpsModule`:

- `RouterRebalanceGuard.validateBatch()` calls `BatchGuardrails.checkBatch()` — validates allocation plan before execution.
- `BatchGuardrails.checkBatch()` calls `PriceOracleMiddleware.isPriceFresh(adapter)` — ensures each allocation target has a fresh oracle price.

These contracts have their own access control (owner, keeper roles) separate from CoreVault's SelectorRegistry.

### 16.4 Module Gas Budget Reference

Approximate gas costs for key module operations (Arbitrum, `FOUNDRY_PROFILE=default`, warm storage):

| Operation | Approx Gas | Notes |
|---|---|---|
| `deposit(1000e6)` | ~140,000 | Includes delegatecall, warmNav check, mint, transfer |
| `requestClaim(true, shares)` | ~110,000 | INSTANT path with epoch cap check |
| `settleFeesAndProcessQueue(n=1)` | ~90,000 | Single claim settlement |
| `deployIdle()` | ~180,000 | Includes StrategyRouter allocation scan |
| `endEpochCrystallize()` | ~70,000 | No perf fee due; ~+40,000 if fee due |
| `markMatured()` (FM) | ~150,000 | Includes final perf fee computation |

Source: estimated from `forge test --gas-report` output on branch `pierdev`. Actual on-chain gas may differ by ±20% depending on oracle update and adapter state.

---

**Code reference**: commit `1595a279` on branch `pierdev` (date: 2026-05-15)

**Source .md files that informed this document** (topic coverage only, no content copied):
- `docs/01-architecture/DIAMOND-LITE-ARCHITECTURE.md` — section coverage check
- `docs/01-architecture/TECH-DESIGN-COMPLETO.md` — module terminology
- `docs/01-architecture/FEECOLLECTOR-SAFETYRESERVE.md` — FeeCollector modes terminology

**Discrepancies found** (code vs. old source .md):
- [^1]: FeeCollector docs may reference `IERC4626Minimal.redeem()` as the harvest path. Code shows `src/core/modules/FeeCollector.sol` uses `IQueueModule.requestClaim(true, bal)` (see `src/core/modules/FeeCollector.sol:56-58`) — corrected in FIX-FEECOLLECTOR-AUTOHARVEST-01. Old sync-redeem flow is broken in v9+ (`AsyncWithdrawalRequired`).
- [^2]: Some docs may list only 8-10 modules. Current codebase has 17: ERC4626Module, QueueModule, AdminModule, BufferManager, FixedMaturityModule, LiquidityOpsModule, FeeCollector, Incentives, IncentivesEngine, BatchGuardrails, PriceOracleMiddleware, ExecutionMemory, StrategyRouter, StrategyScorer, StrategyHealthRegistry, RouterAllocationPolicy, RouterRebalanceGuard.
- [^3]: RouterAllocationPolicy, RouterRebalanceGuard, and ExecutionMemory (`src/core/storage/CoreStorage.sol:100-105`) represent a partially-implemented V10 allocation engine. The feature is optional (controlled by `strictExecutionMemory`) and not fully activated in current production deployment.
