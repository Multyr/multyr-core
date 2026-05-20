# Multyr Core — Storage Layout

> **Status**: draft | **Audit-scope**: multyr-core@pierdev
> **Last reviewed by code**: commit `1595a279` on branch `pierdev` (date: 2026-05-15)
> **Version**: 1.0.0-draft

---

## Table of Contents

1. [Storage Strategy Overview](#1-storage-strategy-overview)
2. [Direct Storage — CoreVault (Slots 0-6)](#2-direct-storage--corevault-slots-0-6)
3. [CoreStorage.Layout — EIP-7201 (dsf.core.main.storage.v1)](#3-corestoragelayout--eip-7201-dsfcoremainsstoragev1)
4. [FeeStorage.Layout — EIP-7201 (dsf.core.fee.storage.v1)](#4-feestoragelayout--eip-7201-dsfcorefeestoragev1)
5. [QueueStorage.Layout — EIP-7201 (dsf.core.queue.storage.v1)](#5-queuestoragelayout--eip-7201-dsfcorequeuestoragev1)
6. [FixedMaturityStorage.Layout — EIP-7201 (dsf.core.fixedmaturity.storage.v1)](#6-fixedmaturitystoragelayout--eip-7201-dsfcorefixedmaturitystoragev1)
7. [BufferManager — Non-Namespaced Storage](#7-buffermanager--non-namespaced-storage)
8. [Storage Interaction Matrix](#8-storage-interaction-matrix)
9. [Upgrade Safety Rules](#9-upgrade-safety-rules)
10. [forge inspect Verification](#10-forge-inspect-verification)
11. [Edge Cases and Pitfalls](#11-edge-cases-and-pitfalls)

---

## 1. Storage Strategy Overview

`CoreVault` uses two distinct storage strategies simultaneously:

### 1.1 Direct Storage (ERC-20/ERC-4626 inheritance + ops cache)

The first 7 slots of `CoreVault`'s storage are used by the inherited OpenZeppelin ERC-20 and ERC-4626 contracts, plus three local variables:

| Slot | Variable | Type | Source |
|---|---|---|---|
| 0 | `_balances` | `mapping(address => uint256)` | OZ ERC20 |
| 1 | `_allowances` | `mapping(address => mapping(address => uint256))` | OZ ERC20 |
| 2 | `_totalSupply` | `uint256` | OZ ERC20 |
| 3 | `_name` | `string` | OZ ERC20 |
| 4 | `_symbol` | `string` | OZ ERC20 |
| 5 | `_opsNavCache` | `uint256` | CoreVault |
| 6 | `_opsNavCacheTs` (bytes 0-7) + `opsNavCacheTtl` (bytes 8-11) | `uint64` + `uint32` | CoreVault |

Verified by `forge inspect CoreVault storage-layout` (see §10).

### 1.2 EIP-7201 Namespaced Storage

All business logic state is stored in four namespaced storage libraries. Each library computes a fixed storage slot as:

```
SLOT = keccak256(abi.encode(uint256(keccak256("namespace")) - 1)) & ~bytes32(uint256(0xff))
```

This guarantees:
- No collision with direct slots (0-6) or other namespaces.
- No collision with future OpenZeppelin upgrades.
- Deterministic slot for external tooling (Etherscan, tenderly).

Because modules execute via `delegatecall`, they share the same storage as `CoreVault`. Each module accesses only its designated namespace:

| Library | Namespace | Used by |
|---|---|---|
| `CoreStorage` | `dsf.core.main.storage.v1` | CoreVault, all modules |
| `FeeStorage` | `dsf.core.fee.storage.v1` | ERC4626Module, QueueModule, AdminModule |
| `QueueStorage` | `dsf.core.queue.storage.v1` | QueueModule |
| `FixedMaturityStorage` | `dsf.core.fixedmaturity.storage.v1` | ERC4626Module, QueueModule, FixedMaturityModule, LiquidityOpsModule |

---

## 2. Direct Storage — CoreVault (Slots 0-6)

Verified via `forge inspect CoreVault storage-layout --json` (see §10 for full output).

### Slot 0 — ERC-20 balances

```solidity
mapping(address => uint256) _balances  // ERC20:line 183 (OZ)
```

Stores per-address vault share balances. Key = user address; value = shares (18 decimals). Modified by `_mint`, `_burn`, `_transfer` — exclusively through `processorMint/Burn/Transfer` for module-context operations.

### Slot 1 — ERC-20 allowances

```solidity
mapping(address => mapping(address => uint256)) _allowances  // ERC20:line 189 (OZ)
```

Standard ERC-20 approval mapping. Modified by `approve()` and consumed by `processorSpendAllowance`.

### Slot 2 — Total supply

```solidity
uint256 _totalSupply  // ERC20:line 191 (OZ)
```

Vault share total supply. Authoritative value used by `totalSupply()`, `convertToAssets()`, all PPS calculations.

### Slot 3 — Token name

```solidity
string _name  // ERC20:line 193 (OZ)
```

ERC-20 name (e.g., "Multyr USDC Vault"). Set in constructor, immutable thereafter.

### Slot 4 — Token symbol

```solidity
string _symbol  // ERC20:line 195 (OZ)
```

ERC-20 symbol (e.g., "mUSDC"). Set in constructor, immutable thereafter.

### Slot 5 — Ops NAV cache value

```solidity
uint256 _opsNavCache  // CoreVault.sol:80
```

Cached NAV for operational decisions (keeper scheduling, pre-flight checks). NOT used for economic math. Updated after every `deposit`, `mint`, `withdraw`, `redeem` call.

### Slot 6 — Ops NAV cache timestamp + TTL

```solidity
uint64 _opsNavCacheTs   // CoreVault.sol:81 — bytes [0, 7]
uint32 opsNavCacheTtl   // CoreVault.sol:82 — bytes [8, 11], default=60s
```

Packed into a single 32-byte slot. `opsNavCacheTtl` is the validity window for `_opsNavCache`. Cache is stale if `block.timestamp >= _opsNavCacheTs + opsNavCacheTtl`.

---

## 3. CoreStorage.Layout — EIP-7201 (dsf.core.main.storage.v1)

```solidity
// CoreStorage.sol:15-16
// keccak256(abi.encode(uint256(keccak256("dsf.core.main.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
bytes32 internal constant SLOT =
    0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00;
```

This is the primary namespace. All modules share this storage. Access via `CoreStorage.layout()` returns a `Layout storage` pointer at `SLOT`.

### 3.1 Component Addresses

| Field | Type | Purpose | Mutability |
|---|---|---|---|
| `params` | `IParamsProvider` | Protocol parameters source | Updatable via AdminModule (timelock if componentsTl) |
| `bufferManager` | `IBufferManager` | Hot/warm buffer manager | Updatable via AdminModule |
| `router` | `IStrategyRouter` | Strategy allocator | Updatable via AdminModule |
| `healthRegistry` | `IStrategyHealthRegistry` | Strategy health state | Updatable via AdminModule |
| `incentives` | `IIncentives` | Legacy incentives (v1) | Updatable via AdminModule |
| `feeCollector` | `address` | Fee recipient | Updatable via AdminModule |
| `vetoer` | `address` | Can veto pending param changes | Updatable via AdminModule |
| `guardian` | `address` | Limited pause authority | Updatable via `setGuardian()` (onlyOwner) |
| `owner` | `address` | Full admin authority | Updatable via 2-step transfer |
| `pendingOwner` | `address` | Transfer target | Set by `beginOwnerTransfer()` |

All address fields occupy 20 bytes and are each in their own storage slot (no packing). Source: `src/core/storage/CoreStorage.sol:39-49`.

### 3.2 Packed Flags and Timestamps

| Field | Type | Purpose | Notes |
|---|---|---|---|
| `packedFlags` | `uint256` | 13-bit flag bitmap | See §4.2 in architecture.md for bit definitions |
| `epochStart` | `uint64` | Current epoch start timestamp | Reset on rollover |
| `lastGuardianPause` | `uint64` | Timestamp of last guardian pause | Cooldown tracking |
| `paramMinDelay` | `uint64` | Minimum timelock delay | Bootstrap=0; production≥2d |

Source: `src/core/storage/CoreStorage.sol:51-54`.

### 3.3 Epoch Tracking

| Field | Type | Purpose |
|---|---|---|
| `epochWithdrawn` | `uint256` | Cumulative INSTANT withdrawals this epoch |
| `currentEpochNumber` | `uint64` | Monotonic epoch counter (anti-spam) |
| `epochDuration` | `uint64` | Epoch duration [1d, 30d], default=7d |
| `lastEpochReset` | `uint64` | Timestamp of last epoch reset (anti-spam) |

Source: `src/core/storage/CoreStorage.sol:57-62`.

`epochWithdrawn` is reset to 0 on epoch rollover by `ExitEngineLib.rollEpochIfNeeded()`. The epoch cap is enforced as `epochWithdrawn + grossAssets <= cap` before any INSTANT settlement.

### 3.4 TVL and NAV Smoothing

| Field | Type | Purpose |
|---|---|---|
| `lastRecordedTVL` | `uint256` | TVL snapshot (used for FM health checks) |
| `lastTVLSnapshot` | `uint64` | Timestamp of TVL snapshot |
| `navSmooth` | `uint256` | EMA of `totalAssets()` |
| `lastNavSmoothUpdate` | `uint64` | Timestamp of last smoothing update |

Source: `src/core/storage/CoreStorage.sol:64-69`. NAV smoothing is updated via `QueueModule.endEpochCrystallize()` → `_updateNavSmooth()`. It uses an exponential moving average with configurable `alphaBps` parameter.

### 3.5 Per-User Mappings

| Field | Type | Purpose |
|---|---|---|
| `lastDepositTs[address]` | `mapping(address => uint64)` | Timestamp of last deposit (lock period check) |
| `blockWithdrawals[blockNumber]` | `mapping(uint256 => uint256)` | Per-block withdrawal accumulator (anti-abuse) |
| `userLastClaimEpoch[address]` | `mapping(address => uint64)` | Last epoch user claimed in (anti-spam) |
| `userClaimsCount[address]` | `mapping(address => uint8)` | Claims count in current epoch |
| `userLastClaimTime[address]` | `mapping(address => uint64)` | Last claim timestamp (cooldown) |

Source: `src/core/storage/CoreStorage.sol:72-76`. These are `mapping` types and each occupies one slot in the Layout struct (the mapping data is stored at `keccak256(key ++ mappingSlot)`).

### 3.6 Module Routing Table

| Field | Type | Purpose |
|---|---|---|
| `moduleOf[bytes4]` | `mapping(bytes4 => address)` | Selector → module address |
| `roleOf[bytes4]` | `mapping(bytes4 => uint8)` | Selector → required role |

Source: `src/core/storage/CoreStorage.sol:79-80`. Populated by `setModule()` / `setModulesBatch()`. Frozen after `freezeRouting()`.

### 3.7 Registry and Seal

| Field | Type | Purpose |
|---|---|---|
| `selectorRegistry` | `address` | SelectorRegistry address (set once, immutable) |
| `pendingSealHash` | `bytes32` | Hash commitment for system sealing |
| `authorizedSealer` | `address` | SystemSealer contract address (set once) |
| `isAuthorizedModule[address]` | `mapping(address => bool)` | Module → processorMint/Burn/Transfer authorized |

Source: `src/core/storage/CoreStorage.sol:83-93`.

### 3.8 Extended Fields (V2 Incentives + V10 Allocation)

| Field | Type | Purpose | Added |
|---|---|---|---|
| `incentivesEngine` | `IIncentivesEngine` | Tranche-based incentives v2 | Post-initial deploy |
| `rewardsPayoutManager` | `address` | Sole reward minting authority | Post-initial deploy |
| `rebalancePolicy` | `address` | Portfolio rebalance policy | V10 allocation engine |
| `rebalanceGuard` | `address` | Rebalance plan validator | V10 allocation engine |
| `executionMemory` | `address` | Allocation cost tracking | V10 allocation engine |
| `strictExecutionMemory` | `bool` | Enforce ExecutionMemory on every deploy | V10 allocation engine |

Source: `src/core/storage/CoreStorage.sol:94-105`. These fields were appended to the Layout struct. Appending to EIP-7201 layout structs is safe — the namespace slot is a hash, and struct fields are allocated sequentially from that slot. No collision with earlier fields.

---

## 4. FeeStorage.Layout — EIP-7201 (dsf.core.fee.storage.v1)

```solidity
// FeeStorage.sol:9-10
bytes32 internal constant SLOT =
    0x70739e319b75b4e5834916b9ca624fcbb6af45b4e67e7e365061fa4e1afc2100;
```

### 4.1 InternalFeeParams (active fee configuration)

```solidity
// FeeStorage.sol:12-18
struct InternalFeeParams {
    uint16 depBps;                    // Deposit fee (basis points)
    uint16 witBps;                    // Withdrawal fee (all exits)
    uint16 immediateExitPenaltyBps;   // Additional for instant exits
    uint16 forceExitPenaltyBps;       // Additional for force exits
    address treasury;                 // Legacy fee recipient (use feeCollector in CoreStorage)
}
```

This struct is packed: four `uint16` values fit in 8 bytes, `address` occupies 20 bytes — total 28 bytes, packs into a single 32-byte slot.

| Field | Max value | Governance cap |
|---|---|---|
| `depBps` | configurable | `params.maxFeeBps()` |
| `witBps` | configurable | `params.maxFeeBps()` |
| `immediateExitPenaltyBps` | configurable | `params.maxImmediateExitPenaltyBps()` |
| `forceExitPenaltyBps` | configurable | `params.maxForceExitPenaltyBps()` |

### 4.2 PendingFeeParams (timelock queue)

```solidity
// FeeStorage.sol:20-28
struct PendingFeeParams {
    uint16  dep;
    uint16  wit;
    uint16  immediateExitPenalty;
    uint16  forceExitPenalty;
    address treasury;
    uint64  eta;    // timestamp after which accept() is valid
    bool    exists; // true if pending change queued
}
```

Fee changes follow submit/accept/revoke:
1. `submitFeeParams()`: sets `pendingFee.exists=true`, `pendingFee.eta = block.timestamp + paramMinDelay`.
2. `acceptFeeParams()`: validates `block.timestamp >= eta` and `block.timestamp < eta + MAX_WINDOW`, copies to `fee`.
3. `revokeFeeParams()`: clears `pendingFee.exists`.

Only one pending fee change can exist at a time — `submitFeeParams` reverts if `pendingFee.exists`. Source: `src/core/modules/AdminModule.sol:82`.

### 4.3 PendingPerfParams (performance fee timelock)

```solidity
// FeeStorage.sol:30-35
struct PendingPerfParams {
    uint256 rateX;
    uint64  minInterval;
    uint64  eta;
    bool    exists;
}
```

### 4.4 PendingMinDelay, PendingBufferManager, PendingRouter

Similar submit/accept/revoke patterns for `paramMinDelay`, `bufferManager`, and `router` component changes. Source: `src/core/storage/FeeStorage.sol:37-54`.

### 4.5 Performance Fee State

| Field | Type | Purpose |
|---|---|---|
| `perfRateX` | `uint256` | Performance fee rate (WAD-scaled) |
| `highWaterMark` | `uint256` | HWM for crystallization (WAD-scaled PPS) |
| `lastCrystallize` | `uint64` | Timestamp of last crystallization |
| `minCrystallizeInterval` | `uint64` | Minimum seconds between crystallizations |

Source: `src/core/storage/FeeStorage.sol:61-66`. `highWaterMark` is initialized to `FixedPoint.WAD` (1e18) on first crystallization.

---

## 5. QueueStorage.Layout — EIP-7201 (dsf.core.queue.storage.v1)

```solidity
// QueueStorage.sol:9-10
bytes32 internal constant SLOT =
    0x20afa2de85fad1e68653d750134f8c4543e7db931009cedccc72142811c77f00;
```

### 5.1 Claim Struct

```solidity
// QueueStorage.sol:16-24
struct Claim {
    address user;    // 20 bytes — slot 0 [0, 19]
    uint64  ts;      // 8  bytes — slot 0 [20, 27] (packed with user)
    bool    immediate; // 1 byte  — slot 0 [28]    (packed with user, ts)
    bool    settled;   // 1 byte  — slot 0 [29]    (packed with user, ts, immediate)
    uint256 shares;  // 32 bytes — slot 1 (separate slot)
}
```

The Claim struct is 2-slot optimized: `user + ts + immediate + settled` pack into slot 0 (30 bytes used), and `shares` occupies slot 1. Total: 64 bytes.

**Critical field semantics**:
- `immediate`: set at creation time. In v9, instant claims that fall back to queue are stored as `immediate = false` (no epoch cap reservation). Source: `src/core/modules/QueueModule.sol:148-150`.
- `settled`: once true, the claim is a ghost entry. Settlement checks `!c.settled && c.shares > 0`.
- `shares`: shares held in escrow by the vault. When `cancelClaim` is called, these are returned to the user.

### 5.2 Layout Fields

| Field | Type | Purpose |
|---|---|---|
| `queue` | `uint256[]` | Ordered array of claim IDs (FIFO) |
| `head` | `uint256` | First valid index (logical head, for O(1) head advance) |
| `nextClaimId` | `uint256` | Auto-increment; starts at 1 (0 = no claim) |
| `pendingShares` | `uint256` | Total shares currently in escrow |
| `claims[claimId]` | `mapping(uint256 => Claim)` | Per-claim data |

Source: `src/core/storage/QueueStorage.sol:24-30`.

### 5.3 Queue Compaction

The `queue` array grows monotonically. `head` advances forward past settled/ghost entries — this achieves O(1) per-claim settlement without array shifting. Periodically, `compactQueue()` can be called by anyone to remove processed head entries and reduce storage rent. Source: `src/core/modules/QueueModule.sol:562-578`.

**Invariant**: `queue.length >= head` always. Active queue length = `queue.length - head`.

### 5.4 Escrow Invariant

The vault holds `pendingShares` worth of shares in escrow (address: `address(this)` in the share `_balances` mapping). The settlement loop checks:

```solidity
// QueueModule.sol:437-443
uint256 escrowBalance = _balanceOf(address(this));
if (escrowBalance < c.shares) {
    emit Events.QueueClaimSkippedEscrowUnderflow(...);
    continue;
}
```

This guards against any accounting inconsistency where the vault's share balance is less than a claim's shares. In a correct deployment, this invariant should never trigger.

---

## 6. FixedMaturityStorage.Layout — EIP-7201 (dsf.core.fixedmaturity.storage.v1)

```solidity
// FixedMaturityStorage.sol:27-28
bytes32 internal constant SLOT =
    0xa3a7555930e5242b25f368378dfab11804bc8d89ad6df651515d4b215e809300;
```

This namespace is only used by FixedMaturity vaults. For OpenEnded vaults, `vaultMode == VaultMode.OpenEnded` causes all gating helpers to early-return with zero overhead.

### 6.1 Mode and State

| Field | Type | Values | Source |
|---|---|---|---|
| `vaultMode` | `VaultMode` enum | `OpenEnded=0`, `FixedMaturity=1` | `src/core/storage/FixedMaturityStorage.sol:11-14` |
| `vaultState` | `VaultState` enum | `Funding=0, Starting=1, Active=2, Matured=3, Closed=4, FundingFailed=5` | `src/core/storage/FixedMaturityStorage.sol:17-24` |

For OpenEnded vaults, `vaultMode = VaultMode.OpenEnded` (0) and `vaultState` is unused.

### 6.2 Configuration Fields (one-shot, set by configureFixedMaturity)

| Field | Type | Purpose |
|---|---|---|
| `fixedTermConfigured` | `bool` | Guard against second `configureFixedMaturity()` call |
| `autoCloseFundingOnTarget` | `bool` | Auto-close funding on `targetFundingAssets` reached |
| `instantEnabledAfterMaturity` | `bool` | Allow INSTANT exits in Matured state |
| `fundingDeadlineTs` | `uint64` | Unix timestamp: deadline for meeting `minFundingAssets` |
| `maturityTs` | `uint64` | Unix timestamp: fixed term end date |
| `startingTs` | `uint64` | Set when `startFixedMaturityCycle()` is called |
| `startTs` | `uint64` | Set when `activateFixedMaturityCycle()` is called |
| `minFundingAssets` | `uint256` | Minimum TVL required to activate cycle |
| `targetFundingAssets` | `uint256` | Target TVL for auto-close |
| `preMaturityForceExitPenaltyBps` | `uint256` | Extra penalty for forceWithdraw in Active state |
| `fixedTermStrategy` | `address` | The strategy that holds fixed-term capital |

Source: `src/core/storage/FixedMaturityStorage.sol:37-52`.

### 6.3 Lifecycle Snapshots

| Field | Type | Purpose |
|---|---|---|
| `fixedTermCommittedAssets` | `uint256` | Net capital locked at Starting transition |
| `retainedHotBuffer` | `uint256` | Hot buffer reserved at Starting (for immediate exits in Funding) |
| `fundingFailedPPS` | `uint256` | PPS snapshot at `markFundingFailed()` — used by `refundClaim()` |
| `finalPerformanceFeeApplied` | `bool` | Guard: applied exactly once at `markMatured()` |
| `finalPerformanceFeeAssets` | `uint256` | Performance fee assessed at maturity |
| `finalPerformanceFeeBaseAssets` | `uint256` | Snapshot of totalAssets at start of `markMatured()` — audit-grade fee basis |
| `fixedTermPrincipalBaseAssets` | `uint256` | Principal snapshot at Funding → Starting (for FM performance calc) |

Source: `src/core/storage/FixedMaturityStorage.sol:53-70`. The `fundingFailedPPS` is immutable after `markFundingFailed()`. `finalPerformanceFeeBaseAssets` is immutable after `markMatured()`.

### 6.4 Gating Helpers

Free functions in `src/core/storage/FixedMaturityStorage.sol` are imported by modules to gate state-dependent operations:

| Helper | Reverts unless |
|---|---|
| `_checkDepositsAllowed(fm)` | `OpenEnded` OR `Funding` state |
| `_checkStandardExitAllowed(fm, instant)` | `OpenEnded` OR `Matured` state |
| `_checkSettlementAllowed(fm)` | `OpenEnded` OR `Matured` state |
| `_checkOpenEndedDeployAllowed(fm)` | `OpenEnded` only |
| `_checkForceExitAllowed(fm)` | `OpenEnded` OR `Active` state |

All have early returns for `OpenEnded`, ensuring zero overhead for non-FM vaults. Source: `src/core/storage/FixedMaturityStorage.sol:85-116`.

---

## 7. BufferManager — Non-Namespaced Storage

`BufferManager` is a standalone contract (not called via delegatecall). It uses classic Solidity storage:

| Slot (approx) | Field | Type | Purpose |
|---|---|---|---|
| — | `core` | `address immutable` | CoreVault address (set in constructor) |
| — | `owner` | `address` | Admin |
| — | `keeper` | `address` | VaultUpkeep contract |
| — | `_cfg` | `BufferConfig` (private struct) | Active buffer configuration |
| — | `_warmAdapters` | `address[]` | Warm adapter addresses |
| — | `warmAdapterQueryGasLimit` | `uint32` | Gas limit for adapter totalAssets() |
| — | `lastRebalanceTs` | `uint40` | Last rebalance timestamp |
| — | `rebalanceCooldown` | `uint32` | Minimum seconds between rebalances (default: 10 min) |
| — | `minRebalanceAmount` | `uint256` | Minimum deploy amount (default: 5,000 USDC) |
| — | `navRefreshInterval` | `uint32` | NAV cache refresh interval (default: 10 min) |
| — | `cachedWarmNav` | `uint256` | Cached sum of warm adapter NAVs |
| — | `lastWarmNavUpdate` | `uint40` | Timestamp of last warm NAV cache update |
| — | `warmNavValid` | `bool` | False if any adapter failed during last update |

Source: `src/core/modules/BufferManager.sol:46-75`. Exact slot numbers depend on field ordering and packing — use `forge inspect BufferManager storage-layout` for precise slots.

**Critical constraint**: BufferManager must NEVER hold idle USDC. All USDC flows directly CoreVault ↔ WarmAdapters. If BufferManager held USDC, `cachedWarmNav` would undercount warm assets, causing deposit dilution. Source: `src/core/modules/BufferManager.sol:16-20`.

---

## 8. Storage Interaction Matrix

Which modules read/write which namespaces:

| Namespace | CoreVault | ERC4626Module | QueueModule | AdminModule | LiquidityOpsModule | FixedMaturityModule |
|---|---|---|---|---|---|---|
| Direct (slots 0-6) | R/W (opsNavCache) | — | — | — | — | — |
| `CoreStorage` | R/W (init, routing) | R (params, flags) | R/W (epoch, user ts) | R/W (components) | R (bm, router) | R (mode flags) |
| `FeeStorage` | R (previewDeposit) | R/W (deposit fee) | R/W (perf fee, crystallize) | R/W (timelock) | — | — |
| `QueueStorage` | R (canSettle) | — | R/W (claims, queue) | — | — | — |
| `FixedMaturityStorage` | — | R (gating) | R (gating) | — | R (gating) | R/W (lifecycle) |

---

## 9. Upgrade Safety Rules

### 9.1 EIP-7201 Layout Append-Only Rule

Fields MAY be appended to any `Layout` struct. They MUST NOT be inserted before existing fields or have their types changed. Inserting or reordering fields would shift all subsequent slots, causing catastrophic storage corruption.

**Correct**: Append new field after all existing fields in the struct.
**Incorrect**: Insert field between existing fields, change field type, change field order.

Example of safe append (applied in v2 incentives + v10 allocation engine):
```solidity
// CoreStorage.sol:94-105 — appended fields
IIncentivesEngine incentivesEngine;
address rewardsPayoutManager;
address rebalancePolicy;
address rebalanceGuard;
address executionMemory;
bool    strictExecutionMemory;
```

### 9.2 Namespace Isolation

Each EIP-7201 namespace is independent. Adding a new namespace library (e.g., `IncentivesStorage`) does not affect existing namespaces, as each derives its slot from a unique string.

### 9.3 Direct Slot Freeze

Slots 0-6 (ERC-20 inherited + ops cache) are effectively frozen. Any new `CoreVault`-level storage MUST use a new EIP-7201 namespace, not a direct slot. Adding direct slots would be safe only if added after the inheritance chain (slot 7+), but this is not the current pattern.

### 9.4 Mapping Slot Safety

Mapping values within Layout structs are stored at `keccak256(key ++ mappingBaseSlot)` where `mappingBaseSlot` is the slot offset within the namespace. If a mapping's base slot changes (due to struct reordering), all existing mapping data becomes inaccessible (reads return 0, writes go to different storage). This is another reason for strict append-only struct evolution.

---

## 10. forge inspect Verification

The following commands were used to verify storage layout alignment:

### 10.1 CoreVault Direct Storage (Verified ✅)

```bash
$ forge inspect CoreVault storage-layout --json
{
  "storage": [
    { "label": "_balances",    "slot": "0", "type": "t_mapping(t_address,t_uint256)" },
    { "label": "_allowances",  "slot": "1", "type": "t_mapping(t_address,...)" },
    { "label": "_totalSupply", "slot": "2", "type": "t_uint256" },
    { "label": "_name",        "slot": "3", "type": "t_string_storage" },
    { "label": "_symbol",      "slot": "4", "type": "t_string_storage" },
    { "label": "_opsNavCache", "slot": "5", "type": "t_uint256" },
    { "label": "_opsNavCacheTs", "slot": "6", "offset": 0, "type": "t_uint64" },
    { "label": "opsNavCacheTtl", "slot": "6", "offset": 8, "type": "t_uint32" }
  ]
}
```

Result: **matches** `src/core/CoreVault.sol:80-82` and inherited OZ fields.

### 10.2 Namespaced Storage (EIP-7201)

EIP-7201 storage is NOT visible in `forge inspect storage-layout` output (the tool only shows direct storage variables). Verification requires reading the code-level SLOT constants and cross-checking with the deployed contract's storage at the expected slot offset.

To verify `CoreStorage.Layout` contents at runtime:
```bash
# Read owner from CoreStorage.layout().owner at computed slot offset
# SLOT = 0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00
# owner is the 9th address field (0-indexed = field 8), offset 8 slots from SLOT
cast storage <CoreVault_address> $(cast to-uint256 $(python3 -c "print(hex(0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00 + 8))"))
```

### 10.3 forge build Verification

```bash
$ forge build
# Compiler output: no warnings on storage layout, no size violations for storage libraries
```

Result: `forge build` exits 0. Storage libraries compile cleanly. Source: run on commit `1595a279`.

---

## 11. Edge Cases and Pitfalls

### 11.1 `_opsNavCacheTs` packing with `opsNavCacheTtl`

Both `_opsNavCacheTs` (uint64) and `opsNavCacheTtl` (uint32) share slot 6. The timestamp is read-written by every deposit/mint/withdraw/redeem. The TTL is a governance parameter changed infrequently. Reading or modifying one does NOT corrupt the other — Solidity handles the byte-level masking automatically. However, any low-level `sstore` to slot 6 MUST correctly mask and pack both values.

### 11.2 `packedFlags` atomic operations

`packedFlags` is a `uint256` bitmap modified with bitwise OR and AND operations. This is NOT atomic across two instructions. In a single-execution-thread EVM context this is fine, but any module upgrade that reads-modifies-writes `packedFlags` in multiple steps within the same delegatecall MUST use in-memory caching, not multiple storage reads. All current code reads `core.packedFlags` once per check.

### 11.3 Layout struct field ordering and gas

Fields in `CoreStorage.Layout` are NOT packed by size (each address occupies its own slot for simplicity, as documented in `src/core/storage/CoreStorage.sol:39`). This is intentional for readability and simplicity — gas cost of per-address reads is considered acceptable given the call patterns. Any optimization attempt that reorders fields would break slot alignment.

### 11.4 Claim `immediate = false` on fallback

When an INSTANT claim falls back to the queue (cap exhausted or lock period not passed), the stored claim has `immediate = false`. This means at settlement time, the standard fee tier applies (witBps only, no immediateExitPenaltyBps) and no epoch cap is consumed. This is a user-favorable design choice to avoid double-penalizing users who attempted an instant exit but were queued. Source: `src/core/modules/QueueModule.sol:148-150`.

### 11.5 fundingFailedPPS immutability

The `fundingFailedPPS` field is a snapshot taken at `markFundingFailed()`. It is NEVER updated after that point. `refundClaim()` uses this value to compute each user's refund amount. If `fundingFailedPPS = 0` at refund time (e.g., called before `markFundingFailed()`), the guard `if (fm.vaultState != VaultState.FundingFailed) revert NotFundingFailed()` protects against this. Source: `src/core/storage/FixedMaturityStorage.sol:56-58`.

---

## 12. Storage Access Patterns by Module

This section documents which functions within each module read or write each storage namespace, providing a precise dependency graph for auditors.

### 12.1 ERC4626Module

| Function | CoreStorage | FeeStorage | QueueStorage | FixedMaturityStorage |
|---|---|---|---|---|
| `deposit()` | R (packedFlags, paramMinDelay, bufferManager) | R (fee.depBps) | — | R (_checkDepositsAllowed) |
| `mint()` | R (packedFlags, bufferManager) | R (fee.depBps) | — | R (_checkDepositsAllowed) |
| `withdraw() / redeem()` | — | — | — | — |
| `forceWithdraw()` | R/W (lastDepositTs, epochStart, packedFlags) | R/W (witBps, forceExitPenaltyBps) | W (new Claim) | R (_checkForceExitAllowed) |
| `forceWithdrawAll()` | R/W (same as forceWithdraw) | R/W (same) | W (new Claims) | R (_checkForceExitAllowed) |
| `_depositInternal()` | R/W (lastDepositTs, packedFlags, navSmooth) | R (depBps) | — | R (gating) |
| `_ensureFreshWarmNav()` | R (bufferManager) | — | — | — |

Source: `src/core/modules/ERC4626Module.sol:81-332`.

### 12.2 QueueModule

| Function | CoreStorage | FeeStorage | QueueStorage | FixedMaturityStorage |
|---|---|---|---|---|
| `requestClaim(immediate, shares)` | R/W (lastDepositTs, epochWithdrawn, epochStart) | R (witBps, immediateExitPenaltyBps) | R/W (new Claim, pendingShares) | R (_checkStandardExitAllowed) |
| `settleFeesAndProcessQueue()` | R/W (epochWithdrawn) | R/W (perf fee, crystallize) | R/W (head, settled) | R (_checkSettlementAllowed) |
| `cancelClaim(claimId)` | R (lastDepositTs) | — | R/W (claim.settled, pendingShares) | — |
| `compactQueue()` | — | — | R/W (queue[], head) | — |
| `endEpochCrystallize()` | R/W (navSmooth, lastCrystallize) | R/W (highWaterMark, perfRateX) | — | — |
| `_settleScan()` | R/W (epochWithdrawn, bufferManager) | — | R/W (head, claims) | R (gating) |
| `_settleLoop()` | R/W (epochWithdrawn) | R (witBps) | R/W (settled, pendingShares) | — |

Source: `src/core/modules/QueueModule.sol:81-803`.

### 12.3 AdminModule

| Function | CoreStorage | FeeStorage | FixedMaturityStorage |
|---|---|---|---|
| `submitFeeParams()` | R (paramMinDelay) | W (pendingFee) | — |
| `acceptFeeParams()` | — | R/W (fee, pendingFee) | — |
| `submitComponentChange()` | R (paramMinDelay) | W (pendingBuffer / pendingRouter) | — |
| `acceptComponentChange()` | W (bufferManager / router) | R/W (pending*) | — |
| `setGuardian()` | W (guardian) | — | — |
| `setOwner()` / `acceptOwner()` | W (owner / pendingOwner) | — | — |
| `setParams()` | W (params) | — | — |
| `pause()` / `unpause()` | R/W (packedFlags, lastGuardianPause) | — | — |
| `seedDeadDeposit()` | R (params, packedFlags) | — | R (_checkDepositsAllowed) |
| `configureFixedMaturity()` | R (packedFlags) | — | W (all FM config fields) |

Source: `src/core/modules/AdminModule.sol:46-487`.

### 12.4 LiquidityOpsModule

| Function | CoreStorage | FeeStorage | FixedMaturityStorage |
|---|---|---|---|
| `deployIdle()` | R (router, bufferManager, rebalancePolicy) | — | R (_checkOpenEndedDeployAllowed) |
| `realizeFromStrategy()` | R (router, bufferManager) | — | — |
| `rebalanceBuffer()` | R (bufferManager) | — | — |
| `deployIdleToAdapters()` | R (bufferManager, rebalancePolicy, executionMemory) | — | R (_checkOpenEndedDeployAllowed) |

Source: `src/core/modules/LiquidityOpsModule.sol:46-350`.

### 12.5 FixedMaturityModule

| Function | CoreStorage | FeeStorage | FixedMaturityStorage |
|---|---|---|---|
| `startFixedMaturityCycle()` | R (router) | — | R/W (vaultState: Funding→Starting) |
| `activateFixedMaturityCycle()` | R (router, bufferManager) | — | R/W (vaultState: Starting→Active, snapshots) |
| `markMatured()` | — | R/W (highWaterMark, finalPerformanceFee) | R/W (vaultState: Active→Matured, finalPerformanceFeeApplied) |
| `closeCycle()` | — | — | R/W (vaultState: Matured→Closed) |
| `markFundingFailed()` | — | — | R/W (vaultState: Funding→FundingFailed, fundingFailedPPS) |
| `refundClaim(claimId)` | — | — | R (fundingFailedPPS, vaultState) |

Source: `src/core/modules/FixedMaturityModule.sol`.

---

## 13. Storage Slot Computation Reference

### 13.1 EIP-7201 Formula

Given a namespace string `N`, the SLOT is:

```
SLOT(N) = keccak256(abi.encode(uint256(keccak256(N)) - 1)) & ~bytes32(uint256(0xff))
```

The `& ~bytes32(uint256(0xff))` operation clears the lowest byte, ensuring the slot is aligned to a 256-byte boundary. This prevents single-mapping or struct reads from colliding with each other.

### 13.2 Known Slot Values

| Namespace String | Slot Constant | File |
|---|---|---|
| `dsf.core.main.storage.v1` | `0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00` | `src/core/storage/CoreStorage.sol:16` |
| `dsf.core.fee.storage.v1` | `0x70739e319b75b4e5834916b9ca624fcbb6af45b4e67e7e365061fa4e1afc2100` | `src/core/storage/FeeStorage.sol:10` |
| `dsf.core.queue.storage.v1` | `0x20afa2de85fad1e68653d750134f8c4543e7db931009cedccc72142811c77f00` | `src/core/storage/QueueStorage.sol:10` |
| `dsf.core.fixedmaturity.storage.v1` | `0xa3a7555930e5242b25f368378dfab11804bc8d89ad6df651515d4b215e809300` | `src/core/storage/FixedMaturityStorage.sol:27` |

> **Historical note**: Prior to run book FIX-EIP7201-SLOTS-01 (2026-05-15), 3 of 4 SLOTs were arbitrary placeholder patterns (`0x5f3e8c9a...`, `0x2b4d6f8a...`, `0x8a3c5e7b...`). Corrected to true EIP-7201 keccak hashes. See FINDING-OOS-03.

### 13.3 Reading EIP-7201 Storage with `cast`

To read a field from `CoreStorage.Layout` at runtime:

```bash
# Read CoreStorage.layout().owner (field index 8, i.e. 9th field starting from 0)
# SLOT + field_offset = 0x5f3e...2d00 + 8 = 0x5f3e...2d08
CORE_VAULT=<deployed_address>
CORE_SLOT=0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00
cast storage $CORE_VAULT $(python3 -c "print(hex(int('$CORE_SLOT', 16) + 8))")
```

For mapping types (e.g., `moduleOf[selector]`), the key is hashed:
```bash
# moduleOf[selector] slot = keccak256(abi.encode(selector, mappingBaseSlot))
cast keccak "$(cast abi-encode 'f(bytes4,uint256)' <selector> <mappingBaseSlot>)"
```

### 13.4 Field Offset Table (CoreStorage.Layout)

Fields are allocated sequentially from `SLOT`. Addresses each occupy one full 32-byte slot (not packed):

| Field Name | Offset from SLOT | Type |
|---|---|---|
| `params` | +0 | address |
| `bufferManager` | +1 | address |
| `router` | +2 | address |
| `healthRegistry` | +3 | address |
| `incentives` | +4 | address |
| `feeCollector` | +5 | address |
| `vetoer` | +6 | address |
| `guardian` | +7 | address |
| `owner` | +8 | address |
| `pendingOwner` | +9 | address |
| `packedFlags` | +10 | uint256 |
| `epochStart` | +11 (packed) | uint64 |
| `epochWithdrawn` | +12 | uint256 |
| `navSmooth` | +13 | uint256 |
| `moduleOf` | +14 | mapping(bytes4 => address) |
| `roleOf` | +15 | mapping(bytes4 => uint8) |

Source: `src/core/storage/CoreStorage.sol:39-106`. Exact offsets verified by manual struct layout analysis.

---

## 14. Common Anti-Patterns

### 14.1 Using Direct Slot Storage for Business Logic

**Anti-pattern**: Reading or writing to slots 0-6 directly for protocol state (e.g., using `_totalSupply` as a TVL proxy).

**Why dangerous**: Slots 0-6 belong to the ERC-20/ERC-4626 inheritance chain. Future OZ upgrades may change the layout. Use `CoreStorage.layout()` for all protocol state.

### 14.2 Caching Namespace Layout Pointer Across Calls

**Anti-pattern**:
```solidity
CoreStorage.Layout storage core = CoreStorage.layout();
// ... external call here ...
// using core.owner after the external call
```

**Why dangerous**: External calls can modify storage. A `Layout storage` pointer is valid at the instant it is created, but fields accessed after an external call may observe new values (which is correct) or, if a reentrancy vulnerability exists, corrupted values. Always re-fetch `layout()` after any external call if the field semantics require a fresh read.

### 14.3 Using `opsNavCache` for Economic Math

**Anti-pattern**: Using `_opsNavCache` (slot 5) for share price computation in deposit/withdrawal paths.

**Why dangerous**: `_opsNavCache` is for keeper scheduling only and has a configurable TTL. It may be stale. All economic math MUST call `totalAssets()` directly. Source: `src/core/CoreVault.sol:643-658` comment block.

### 14.4 Partial `packedFlags` Write via Low-Level Assembly

**Anti-pattern**: Using `sstore` to slot 10 (the `packedFlags` slot) with a hardcoded mask that doesn't account for other bits.

**Why dangerous**: `packedFlags` contains 13 active bits. A low-level write that masks out unknown bits can silently clear the REENTRANCY_LOCKED or SYSTEM_SEALED flags. Always use the high-level `CoreStorage.layout().packedFlags |= (1 << FLAG_*);` pattern.

### 14.5 Treating `pendingShares` as Share Count for NAV

**Anti-pattern**: Including `QueueStorage.layout().pendingShares` in totalSupply or totalAssets computations.

**Why dangerous**: Shares held in escrow (pending queue claims) are already counted in `_totalSupply` (slot 2) and `_balances[address(this)]`. Including them again would double-count, artificially increasing share supply and deflating PPS.

---

## 15. Storage Namespace Cross-Reference

Quick reference for auditors navigating the codebase:

| What you're looking for | Where to look | Key constant / function |
|---|---|---|
| Is vault paused? | `CoreStorage.layout().packedFlags & (1 << 0)` | `FLAG_PAUSED = 0` (`src/core/storage/CoreStorage.sol:24`) |
| Is routing frozen? | `CoreStorage.layout().packedFlags & (1 << 6)` | `FLAG_ROUTING_FROZEN = 6` (`src/core/storage/CoreStorage.sol:30`) |
| Is system sealed? | `CoreStorage.layout().packedFlags & (1 << 9)` | `FLAG_SYSTEM_SEALED = 9` (`src/core/storage/CoreStorage.sol:33`) |
| Current epoch withdrawn | `CoreStorage.layout().epochWithdrawn` | `src/core/storage/CoreStorage.sol:57` |
| Active module for selector | `CoreStorage.layout().moduleOf[selector]` | `src/core/storage/CoreStorage.sol:79` |
| Active fee config | `FeeStorage.layout().fee` | `src/core/storage/FeeStorage.sol:55` |
| Pending fee change | `FeeStorage.layout().pendingFee.exists` | `src/core/storage/FeeStorage.sol:56` |
| HWM for perf fee | `FeeStorage.layout().highWaterMark` | `src/core/storage/FeeStorage.sol:63` |
| Active queue head | `QueueStorage.layout().head` | `src/core/storage/QueueStorage.sol:26` |
| Total escrowed shares | `QueueStorage.layout().pendingShares` | `src/core/storage/QueueStorage.sol:28` |
| Vault mode (OE vs FM) | `FixedMaturityStorage.layout().vaultMode` | `src/core/storage/FixedMaturityStorage.sol:31` |
| FM lifecycle state | `FixedMaturityStorage.layout().vaultState` | `src/core/storage/FixedMaturityStorage.sol:32` |
| Funding deadline | `FixedMaturityStorage.layout().fundingDeadlineTs` | `src/core/storage/FixedMaturityStorage.sol:37` |

---

**Code reference**: commit `1595a279` on branch `pierdev` (date: 2026-05-15)

**Source .md files that informed this document** (topic coverage only, no content copied):
- `docs/01-architecture/SHARED-VS-PERVAULT.md` — storage rationale section
- `docs/01-architecture/TECH-DESIGN-COMPLETO.md` — section coverage check

**Discrepancies found** (code vs. old source .md):
- [^1]: Older architecture docs may describe "vault-global storage" without EIP-7201 namespace. Code confirms EIP-7201 is used for all business logic state (4 namespaces). Direct slots 0-6 are only ERC-20 inherited + ops cache.
- [^2]: `FeeStorage.InternalFeeParams.treasury` (legacy field) is documented as "legacy, now feeCollector" in the struct comment (`src/core/storage/FeeStorage.sol:17`). Active fee routing uses `CoreStorage.layout().feeCollector`, not this legacy treasury field. The treasury field is set via `submitFeeParams` but not actively read for fee transfers.
