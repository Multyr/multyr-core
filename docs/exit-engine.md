# Exit Engine

The production exit paths are implemented by `EpochedQueueModule`, `ERC4626Module` and
`ExitEngineLib`. [Economic exit](economic-exit.md) fixes ordinary withdrawal value at request
time. [Queue mechanics](queue-mechanics.md) describes settlement and cohort accounting.

## 1. Public paths

| Path | Pricing and settlement | Fee tier | Deposit lock | Instant cap |
|---|---|---|---|---|
| `requestEpochWithdrawal(shares)` | Price and burn at request; claim after funding | `witBps` | Enforced | Not consumed |
| Eligible `requestInstantWithdrawal(shares)` | Price, burn and pay in one transaction | `witBps + immediateExitPenaltyBps` | Enforced | Net payout consumed |
| Instant fallback | Same fixed-liability queue as standard | `witBps` | Enforced | Not consumed |
| `forceWithdraw(...)` | Synchronous, caller-supplied redemption plan | Force tier | Bypassed | Not consumed |
| `forceWithdrawAll(receiver, minAssetsOut)` | Best-effort liquidity waterfall and proportional fill | Force tier | Bypassed | Not consumed |

ERC-4626 `withdraw` and `redeem` revert `AsyncWithdrawalRequired`; `maxWithdraw` and
`maxRedeem` return zero. Fixed-maturity state and pause gates apply independently.

## 2. Ordinary request accounting

Both standard and instant entrypoints roll the cap epoch before asset/supply changes and
attempt to refresh stale warm NAV. Instant eligibility is evaluated after refresh using
gross share value, so a stale cached valuation cannot select an incorrect fee tier.
`_crystallizeExit(user, shares, mode)` is the shared pricing helper:

1. Require positive shareholder equity (`grossAssets > totalOwed`) and valid, fresh NAV.
2. Compute fee shares rounded up; net shares are gross shares less fee shares.
3. Convert net shares to assets once, before the burn, rounding down; reject zero owed.
4. Transfer fee shares from the user to `feeCollector`, burn net shares, and add the fixed
   asset liability to `totalOwed`.

A queued request records that liability. Instant payment discharges it in the same
transaction. Closing or claiming never reapplies an exit fee or reprices the shares.
There is no cancellation or escrow. The legacy `minClaimAmount` does not enforce an exit
floor; a positive-share request that rounds to zero assets is rejected to prevent empty claims.

## 3. NAV and settlement

`CoreVault.grossAssets()` sums physical hot, warm and enabled-strategy NAV.
`totalAssets() = max(grossAssets() - totalOwed(), 0)` is shareholder equity used for ERC-4626
conversions and performance fees. Reserves are already included in liabilities and must
not be subtracted from NAV twice. Available hot liquidity excludes `reservedForClaims`.

An epoch progresses Open → Closed → Funded. Close only changes the settlement bucket.
Funding sizes unfunded cohorts against free portfolio assets after existing funded reserves,
attempts liquidity recovery, then fixes `recoveryIndex` and writes off the unfunded haircut.
Claims pay their nominal `assetsOwed` multiplied by that fixed index, rounded down.
Neither later recoveries nor claim order reopens the ratio.

Before an initial below-nominal funding target is accepted, `fundEpoch` attempts a soft
warm NAV refresh and recomputes its target. Invalid NAV leaves the epoch Closed and emits
`EpochFundingNavInvalid`. Funding also rechecks after liquidity operations. A persistent
DEGRADED strategy cannot be written down automatically. Follow the
[insolvency governance runbook](economic-exit.md#71-insolvency-governance-runbook): recover
assets before disabling a strategy or removing a warm adapter. Excluding value before
recovery can permanently reduce the exiting cohort's settlement.

## 4. Instant cap

Settlement epochs and cap epochs are independent. `ExitEngineLib.rollCapEpochIfNeeded`
rolls the latter and captures shareholder NAV before changes to assets or supply. A zero
configured duration skips rollover. The stored base is `CoreStorage.capBaseSnapshot`;
`epochWithdrawn` tracks successful instant net payouts.

The cap uses `WithdrawalParams.capPerEpochBps`. A zero value is uncapped. Within an active
cap epoch, requests and queue activity do not reduce the snapshot merely by creating
liabilities or burning shares. Legacy `DynamicCapParams` and `outstandingClaimCount` have
no effect on production instant-cap enforcement or the lens.

Eligibility compares gross request value with the remaining cap and free liquidity.
A successful instant payout consumes only its net asset amount. Cap exhaustion, insufficient
instant liquidity or the instant-only breaker can select the standard queued fallback;
the queued-request breaker may still reject that fallback. An active deposit lock rejects
ordinary requests rather than allowing a fallback to bypass it.

## 5. Fees and force exits

Exit fees are paid in existing shares, transferred to `feeCollector`; net shares are burned.
The instant penalty applies only when the instant path is eligible. Standard queued requests
and instant fallbacks use the standard tier. The force tier adds `forceExitPenaltyBps`, plus
the applicable pre-maturity penalty in FixedMaturity Active state. Fee changes retain the
AdminModule submit/accept/revoke timelock flow. Performance-fee crystallization is separate
from request and settlement and measures shareholder NAV net of liabilities.

`forceWithdraw` takes an asset target, receiver, owner, a caller-supplied strategy plan and
`maxShares`. It bypasses the ordinary lock and instant cap but its router redemption path
still enforces oracle freshness. It is not a guaranteed stale-oracle escape.

`forceWithdrawAll` uses hot → warm → strategy liquidity with the router's force-redemption
path, which has no oracle freshness check. It burns/transfers only shares corresponding to
the actual fill, leaving unfilled shares live and retriable. `minAssetsOut` protects the
caller. Force exits respect funded claim reservations and the force-exit pause gate;
no path can guarantee cash recovery from an illiquid or failed external strategy.

## 6. Access, external calls and failures

Ordinary requests are public but act on the caller's shares. Close and fund are permissionless.
Single claims require their owner; batch claims process only the caller's unclaimed entries.
Manual claiming remains available independently of keeper scheduling.

Warm refresh/refill and incentive notifications use best-effort handling where implemented.
That does not waive NAV, solvency, lock, pause or token-transfer checks. The warm cache has
a 15-minute validity window. Failed refreshes still block ordinary pricing or haircut
crystallization if inputs remain invalid. Funded claims use their locked ratio without
requiring fresh request-time NAV. Failed payout transfers revert and preserve the claim.

Funding tolerates at most one underlying base unit of insolvency rounding and never reserves
unavailable cash. Claim payout coverage similarly permits only one base unit; larger deficits
revert. `EpochFundingShortfall` identifies deferred funding, and `EpochFundingNavInvalid`
identifies invalid valuation. `EpochRecoveryCrystallized` records each cohort's ratio and loss.

## 7. Example and invariants

At a conversion rate of one asset per share, a standard request of 1,000 shares with a 0.5%
fee transfers 5 fee shares, burns 995 net shares and records 995 assets owed immediately.
Closing the epoch does not change that amount. Solvent funding reserves 995 and fixes index
1; funding at a 0.6 recovery ratio reserves 597 and writes off 398. The owner then receives
597 even if portfolio value subsequently recovers. Later recovery belongs to active equity.

The core invariants are: price before burning; transfer rather than mint exit fee shares;
never double-subtract reserves from NAV; protect other cohorts' cash; never crystallize a
haircut on invalid NAV; never reprice a Funded cohort; and never consume instant cap for a
standard queued or force exit. Economic-exit unit and fork suites exercise these guarantees.
