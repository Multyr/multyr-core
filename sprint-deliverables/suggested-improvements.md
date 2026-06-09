# Suggested Improvements

This file separates completed sprint fixes from remaining hardening items.

## Completed During Sprint

### DepositFor Unauthorized Payer

- Replaced the unsafe three-argument `depositFor(assets, receiver, payer)` model
  with `depositFor(uint256 assets, address receiver)`.
- The payer is now always `msg.sender`.
- DepositRouter/Permit2 must pull user tokens into the router first, then call
  `depositFor(amount, user)` or `deposit(amount, user)`.
- Covered by `test/sprint-test/DepositFor_UnauthorizedPayer_POC.t.sol`.

### DeployToStrategiesWithPlan Drain

- Changed `deployToStrategiesWithPlan` from `ROLE_PUBLIC` to
  `ROLE_OWNER_OR_GUARDIAN`.
- Added validation that every external plan destination is an enabled strategy
  before any USDC transfer occurs.
- Kept the auto-planned `deployToStrategies(maxAmount)` path public because the
  caller does not control destination addresses.
- Covered by `test/sprint-test/DeployToStrategiesWithPlan_Drain.t.sol`.

### High-Water Mark Drawdown

- Preserved HWM during drawdowns instead of lowering it to depressed PPS.
- Moved the `minCrystallizeInterval` guard inside `_crystallize`.
- Prevented public `endEpochCrystallize` from charging fees before the minimum
  interval has elapsed.
- Covered by `test/sprint-test/HWM_Drawdown_POC.t.sol`.

### AdminModule Governance Bypasses

- Added `FLAG_COMPONENTS_TIMELOCKED` guard to `setEcosystem`.
- Added pending-exists guards to `submitPerfParams`, `submitMinDelay`,
  `submitBufferManager`, and `submitRouter`.
- Covered by `test/sprint-test/AdminModule_GovernanceBypass_POC.t.sol`.

### SystemSealer Timestamp Hash

- Added the single-call `SystemSealer.verifyAndSeal(config)` production path.
- Added `CoreVault.sealBySealer(configHash)` so the sealer can record the hash
  and set `FLAG_SYSTEM_SEALED` atomically.
- Removed timestamp dependency from the review seal hash.
- Covered by `test/sprint-test/SystemSealer_TimestampHash_POC.t.sol`.

## Remaining Hardening Items

### 1. Add Slippage Protection To forceWithdrawAll

`forceWithdrawAll(address receiver)` still burns all caller shares and pays a
best-effort amount. If strategy liquidity is frozen or partial, the user may
receive materially less than `targetAssets`.

Recommended fix:

- add `forceWithdrawAll(address receiver, uint256 minAssetsOut)`, or
- rename current behavior to `emergencyExitBestEffort`, then add an exact/protected
  all-shares variant, or
- burn shares only proportional to assets actually delivered and preserve a
  residual claim for unpaid value.

Status: open residual risk. See `ForceWithdrawAll_SlippagePOC.t.sol`.

### 2. Tighten External Plan Validation

The critical external-plan drain is fixed, but two small validation cleanups are
worth adding:

- reject zero-amount legs instead of silently skipping them
- reject caller-supplied `fundsAlreadyTransferred == true` on external plans

These make the external-plan API less ambiguous.

### 3. Refresh Warm NAV Before Slippage Previews

The slippage-protected `deposit` and `mint` overloads calculate expected
shares/assets before `_depositInternal` or `_mintInternal` refreshes stale warm
NAV.

Recommended fix:

- call the same warm-NAV refresh before previewing, or
- re-check the final computed value immediately before transferring assets.

### 4. Align mint Hooks With deposit

`_depositInternal` notifies incentives and can trigger fixed-maturity auto-close.
`_mintInternal` currently mirrors fee accounting but does not trigger all the
same hooks.

Recommended fix:

- either add the same incentives/FM hooks to `_mintInternal`, or
- document and test why exact-share minting intentionally differs.

### 5. Strengthen SystemSealer Live Wiring Checks

`SystemSealer` verifies ownership/governance of configured components. The next
hardening step is to also assert that the configured component addresses exactly
match the live addresses stored in the vault's ecosystem config.

Recommended fix:

- compare `IAdminModule(vault).getEcosystem()` against `SealConfig`
- verify `selectorRegistry`, `feeCollector`, `globalConfig`, `router`, buffer,
  health registry, incentives, rewards payout manager, and guardian/vetoer in
  one place
