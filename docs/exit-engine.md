# Exit Engine

`ExitEngineLib` centralizes fee-share arithmetic, cap rollover, cap consumption and exit
simulation. `EpochedQueueModule` orchestrates ordinary economic exits; `ERC4626Module`
handles deposits, minting and force exits. See [economic-exit.md](economic-exit.md) for
accounting policy and [queue-mechanics.md](queue-mechanics.md) for funding and claims.

## 1. Public exit paths

| Mode | Entrypoint | Fee tier | Instant cap | Deposit lock |
|---|---|---|---|---|
| Standard | `requestEpochWithdrawal(shares)` | `witBps` | No consumption | Required |
| Instant | `requestInstantWithdrawal(shares)` | `witBps + immediateExitPenaltyBps` on success | Net payout consumed | Required |
| Force | `forceWithdraw` / `forceWithdrawAll` | Force-exit fee policy | No consumption | Bypassed |

Synchronous ERC-4626 `withdraw` and `redeem` revert `AsyncWithdrawalRequired`;
`maxWithdraw` and `maxRedeem` return zero. Ordinary requests cannot be cancelled.
Fixed-maturity state gates apply in addition to the mode-specific rules.

## 2. Ordinary request pricing and fees

Both paths acquire the reentrancy guard and roll the cap epoch before changing assets
or supply. They enforce the deposit lock, attempt a stale warm-cache refresh, require
valid NAV, and reject insolvency/zero equity. A rounded-zero liability is rejected.

`computeFeeShares` applies the selected mode's basis points, rounds fee shares up and
returns `netShares = grossShares - feeShares`. `_crystallizeExit` prices net shares before
the burn, transfers fee shares to the collector, burns net shares, and records `assetsOwed`
in `totalOwed`. Fees are share transfers; ordinary exits do not mint supply.

Instant requests check the refreshed gross share value against the allowance and available
hot/warm liquidity before selecting a fee tier. A cap/liquidity failure or instant pause
records a standard-fee claim. NAV invalidity and active locks revert instead of falling back.
On instant success the liability is discharged and its net payout consumes the cap.

## 3. Cap computation and rollover

`CoreStorage` stores `epochStart`, `epochDuration`, `epochWithdrawn` and `capBaseSnapshot`.
The snapshot is shareholder NAV, `max(0, grossAssets - totalOwed)`, taken before the first
asset/supply mutation after rollover. A zero snapshot is backfilled by an interaction
with nonzero shareholder assets. An unconfigured zero duration skips rollover safely.

```text
cap       = floor(capBaseSnapshot * capPerEpochBps / 10000)
remaining = max(0, cap - epochWithdrawn)
```

`DynamicCapParams` is retained for compatibility and ignored by enforcement and the lens.
Standard requests, their funding/claims, and force exits never consume the instant cap.
A cap epoch is separate from the settlement epochs that group queued requests.

## 4. Settlement and insolvency

Queued requests fix nominal amounts individually. Closing groups them for funding without
repricing, transferring fees or burning shares. Funding uses assets and liabilities net
of other cohorts' reserves, reconciles liquidity, and fixes one immutable recovery ratio.
A haircut requires valid NAV; stale warm NAV receives a soft refresh before sizing again.
Only one underlying base unit of insolvency rounding shortfall is allowed.

Manual or automatic settlement pays each owner at the fixed cohort index, reduces reserves
and liabilities, and marks the claim settled. Funding write-downs remove losses from
`totalOwed` once. Later recovery belongs to remaining shareholders. Governance follows
[recover-first insolvency procedures](insolvency-runbook.md) before recognizing a loss.

## 5. Force exits

`forceWithdraw(assets, receiver, owner, plan, maxShares)` uses a caller-provided strategy
pull plan, checks allowances/limits and retains the router's normal loss/oracle guards.
`forceWithdrawAll(receiver, minAssetsOut)` uses the dedicated best-effort force redemption path;
its minimum output protects the caller from accepting an insufficient fill. Force exits
bypass the deposit lock and instant cap, but remain subject to their dedicated breaker
and fixed-maturity state gates. Zero shareholder equity cannot support a payout.

Free cash excludes funded claims' reserves. Force exit does not authorize spending
cash earmarked for other users. No force-exit call guarantees cash from an illiquid or
failed strategy. Exact signatures and access checks are in `ERC4626Module.sol`.

## 6. Simulation and performance fees

`ExitResult` includes gross/net assets, fee/net shares, fee components, queue selection and
remaining cap. Simulation is a quote against its supplied NAV and configuration. Runtime
ordinary requests refresh NAV before pricing, so a prior view quote can change before
execution. No claim is repriced at settlement.

Performance fee crystallization uses shareholder NAV and the high-water mark in
`FeeStorage`. It is independent of the request's exit fee and of settlement-epoch closing.
Performance fee shares may be minted according to that policy; ordinary exit fees are
transferred from the exiting owner. Fee configuration follows the governance timelock.

## 7. Automatic settlement and costs

Automatic claim settlement is a required service. It preserves permissionless owner
self-claim as a fallback. The protocol funds the upkeep; the withdrawal request transaction
is still submitted by the user. Instant payouts do not create an additional claim-settlement
transaction. See [settlement operations and budgeting](claim-settlement-operations.md).

## 8. Validation

`EconomicExit_Spec.t.sol` and `EconomicExit_Gaps.t.sol` exercise cohort funding, NAV gates,
refresh behavior, cap snapshots and rounding boundaries. `ClaimSettlementUpkeep.t.sol`
covers bounded scans, idle-history suppression, failed recipients, manual fallback and
zero-recovery accounting. `FeeCollectorHarvestQueue.t.sol` covers already-settled claims.
