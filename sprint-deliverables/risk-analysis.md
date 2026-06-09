# Risk Analysis

Final review risk analysis for the sprint POCs.

## Executive Summary

The sprint focused on high-impact issues around arbitrary asset movement,
governance bypasses, fee accounting, and deployment sealing. Most POC findings
now have code-level fixes and regression tests. One finding remains an explicit
residual design risk: `forceWithdrawAll` is still best-effort and lacks a
`minAssetsOut` guard.

## Findings Table

| ID | Finding | Severity | Status |
|---|---|---:|---|
| F-01 | `deployToStrategiesWithPlan` arbitrary surplus drain | Critical | Fixed |
| F-02 | `depositFor` unauthorized payer / approval theft | Critical | Fixed |
| F-03 | `forceWithdrawAll` partial payout while burning all shares | High | Open residual risk |
| F-04 | HWM lowered on drawdown, enabling fees on loss recovery | High | Fixed |
| F-05 | Performance fee interval guard was advisory only | Medium | Fixed |
| F-06 | `setEcosystem` bypassed component timelock | High | Fixed |
| F-07 | Pending governance submissions could be silently overwritten | Medium | Fixed |
| F-08 | `SystemSealer` timestamp hash made atomic timelock seal impossible | Medium | Fixed |

## F-01: deployToStrategiesWithPlan Arbitrary Surplus Drain

**Severity:** Critical

**POC:** `test/sprint-test/DeployToStrategiesWithPlan_Drain.t.sol`

**Affected area:** `LiquidityOpsModule`, `SelectorRegistry`, deployment wiring

### Issue

`deployToStrategiesWithPlan` accepted a caller-supplied allocation plan and was
previously public. The module validated only that the plan total did not exceed
deployable surplus, then transferred vault USDC directly to `plan[i].strat`.

An attacker could set `plan[0].strat = attacker` and drain the vault's hot
deployable surplus.

### Exploit Scenario

1. Vault has 1,000,000 USDC hot balance.
2. Buffer settings allow 700,000 to 1,000,000 USDC deployable surplus.
3. Attacker calls `deployToStrategiesWithPlan`.
4. Malicious plan sends funds to the attacker's EOA.
5. Vault transfers USDC directly to the attacker.

### Fix

- `deployToStrategiesWithPlan` now requires `ROLE_OWNER_OR_GUARDIAN`.
- `deployToStrategies` remains public because it uses `router.planDeposit` and
  the caller cannot choose destinations.
- `LiquidityOpsModule` validates each external plan leg with
  `router.isStrategyEnabled(plan[i].strat)` before transfer.
- Deployment helper role assignment was updated to match this policy.

### Residual Risk

Low after the fix. Recommended cleanup: reject zero amount plan legs and reject
caller-supplied `fundsAlreadyTransferred == true`.

## F-02: depositFor Unauthorized Payer

**Severity:** Critical

**POC:** `test/sprint-test/DepositFor_UnauthorizedPayer_POC.t.sol`

**Affected area:** `ERC4626Module`, selector registry, DepositRouter integration

### Issue

The old design accepted `depositFor(assets, receiver, payer)`. Any caller could
choose a victim as `payer`, rely on the victim's standing vault allowance, and
mint shares to the attacker.

### Exploit Scenario

1. Victim approves vault for USDC.
2. Attacker calls `depositFor(amount, attacker, victim)`.
3. Vault transfers USDC from victim.
4. Attacker receives shares and can exit for value.

### Fix

- Removed the arbitrary payer parameter.
- Current function is `depositFor(uint256 assets, address receiver)`.
- The payer is always `msg.sender`.
- DepositRouter must pull tokens from the user into the router first using
  Permit2, then call `depositFor(amount, user)` or `deposit(amount, user)`.

### Residual Risk

Low. The remaining security boundary moves to the DepositRouter implementation:
it must not expose a user-chosen payer to the vault.

## F-03: forceWithdrawAll Partial Payout / Full Share Burn

**Severity:** High

**POC:** `test/sprint-test/ForceWithdrawAll_SlippagePOC.t.sol`

**Affected area:** `ERC4626Module.forceWithdrawAll`, `StrategyRouter.forceRedeemForWithdraw`

### Issue

`forceWithdrawAll` calculates a target value from all caller shares, attempts
best-effort liquidity extraction, burns all net shares, then pays only
`min(hot balance, targetAssets)`.

If a strategy is frozen, illiquid, or returns a partial amount, the user may
receive far less than fair value while losing the entire share position.

### Exploit / Loss Scenario

1. User owns 1,000,000 USDC worth of shares.
2. 900,000 USDC of vault assets are in a frozen strategy.
3. User calls `forceWithdrawAll`.
4. Router skips or partially pulls from the strategy.
5. Vault burns all user shares.
6. User receives only available hot liquidity, for example 100,000 USDC.

### Fix / Resolution

No full code fix is currently applied. The current behavior is best-effort and
must be treated as a residual design risk.

Recommended production fix:

- add `forceWithdrawAll(receiver, minAssetsOut)` and revert if payout is below
  the user-provided floor, or
- keep current behavior under a clearer name such as `emergencyExitBestEffort`
  and add a separate protected all-shares exit, or
- burn shares only for the value actually paid and keep a residual claim for the
  unpaid amount.

### Residual Risk

High until one of the protected designs is implemented.

## F-04: HWM Lowered On Drawdown

**Severity:** High

**POC:** `test/sprint-test/HWM_Drawdown_POC.t.sol`

**Affected area:** `QueueModule._crystallize`, legacy `PerfFeeMixin._crystallize`

### Issue

On drawdown, the previous logic could write the current depressed PPS into HWM.
That made HWM decrease. Later, as PPS recovered from the loss, the protocol
could charge performance fees even though users were still underwater.

### Exploit Scenario

1. HWM reaches 1.10.
2. Vault suffers drawdown to 0.50.
3. Public crystallization lowers HWM to 0.50.
4. PPS recovers to 0.80.
5. Protocol charges a performance fee on recovery even though PPS is below 1.10.

### Fix

- HWM is now monotonically non-decreasing.
- Drawdown crystallization records the event but writes back the previous HWM.
- Fees are only charged when PPS exceeds the preserved HWM.

### Residual Risk

Low after the fix.

## F-05: Crystallize Interval Guard Bypass

**Severity:** Medium

**POC:** `test/sprint-test/HWM_Drawdown_POC.t.sol`

**Affected area:** `QueueModule._crystallize`, legacy `PerfFeeMixin._crystallize`

### Issue

`canCrystallize()` checked the minimum crystallization interval, but
`_crystallize()` did not. Since `endEpochCrystallize()` is public, a caller
could reach `_crystallize()` directly and trigger fee extraction before the
configured interval elapsed.

### Exploit Scenario

1. Performance fee crystallizes once.
2. More yield arrives before `minCrystallizeInterval`.
3. Anyone calls public `endEpochCrystallize()`.
4. Fees are charged again despite the interval.

### Fix

- The interval check is now enforced inside `_crystallize()`.
- Calls inside the minimum interval return without minting a fee.

### Residual Risk

Low after the fix.

## F-06: setEcosystem Component Timelock Bypass

**Severity:** High

**POC:** `test/sprint-test/AdminModule_GovernanceBypass_POC.t.sol`

**Affected area:** `AdminModule.setEcosystem`

### Issue

Once `enableComponentsTimelock()` was called, individual setters such as
`setBufferManager` and `setRouter` were blocked. `setEcosystem`, however, could
still atomically change both critical components without delay.

### Exploit Scenario

1. Component timelock is enabled.
2. Owner or compromised owner key calls `setEcosystem` directly.
3. Buffer manager and router are swapped to malicious contracts with no delay.
4. Vetoer and users have no timelock window to react.

### Fix

- `setEcosystem` now checks `FLAG_COMPONENTS_TIMELOCKED`.
- After component timelock is enabled, component changes must use
  `submitBufferManager` / `acceptBufferManager` and `submitRouter` /
  `acceptRouter`.

### Residual Risk

Low after the fix.

## F-07: Pending Governance Submission Overwrite

**Severity:** Medium

**POC:** `test/sprint-test/AdminModule_GovernanceBypass_POC.t.sol`

**Affected area:** `AdminModule`

### Issue

Some submit functions could overwrite a live pending change before it was
accepted or revoked. This could mislead vetoers monitoring the first submitted
payload.

### Exploit Scenario

1. Owner submits acceptable parameters.
2. Vetoer sees the event and decides not to revoke.
3. Owner overwrites the pending slot with worse parameters.
4. The final accepted value differs from what the vetoer reviewed.

### Fix

Added `PendingParamsNotResolved` guards to:

- `submitPerfParams`
- `submitMinDelay`
- `submitBufferManager`
- `submitRouter`

### Residual Risk

Low after the fix.

## F-08: SystemSealer Timestamp Hash / Unbatchable Seal

**Severity:** Medium

**POC:** `test/sprint-test/SystemSealer_TimestampHash_POC.t.sol`

**Affected area:** `SystemSealer`, `CoreVault` seal path

### Issue

The previous two-step seal design used a hash containing `block.timestamp`.
Timelock batches cannot pass return values between calls, and the timestamp at
schedule time differs from execution time. This made the atomic batch
unreliable or impossible.

### Exploit / Failure Scenario

1. Operator schedules `prepareSeal(config)` and `sealFinalState(hash)`.
2. `hash` cannot be known for the future execution timestamp.
3. Batch executes after delay.
4. `sealFinalState` sees a mismatch and reverts.
5. Vault remains unsealed despite correct configuration.

### Fix

- Added `SystemSealer.verifyAndSeal(config)`.
- Added `CoreVault.sealBySealer(configHash)`.
- Hash is deterministic and excludes `block.timestamp`.
- Root timelock schedules one call, and sealing is atomic.

### Residual Risk

Low after the fix. Recommended hardening: compare every `SealConfig` component
against live vault wiring, not only ownership/governance of the supplied
addresses.

## Review Talking Points

- The two critical arbitrary asset movement findings were fixed by removing
  caller-controlled payer/destination authority.
- Governance fixes make pending values non-overwritable and component changes
  respect timelocks.
- HWM fixes protect users from paying performance fees on loss recovery.
- The seal fix turns a fragile two-call process into a deterministic single
  timelock operation.
- `forceWithdrawAll` remains the main open design decision.
