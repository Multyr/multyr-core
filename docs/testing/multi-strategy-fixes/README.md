# Multi-strategy failure remediation

This is a source patch and local regression package, not a mainnet deployment or burn-in acceptance. Original results remain in `../multi-strategy-fork-20261101/results.json` and `before-results.json`. No production transactions were sent. The stopped burn scheduler was not resumed.

## Verified results

- Expanded pinned-fork suite: **48 passed, 0 failed**.
- Targeted unit suite: **45 passed, 0 failed** (38 existing and 7 new).
- Candidate router runtime: **24,472 bytes**, below the 24,576-byte EIP-170 limit; only 104 bytes of margin remain.
- Candidate liquidity module runtime: **16,226 bytes**.
- Planner compilation passed.
- Broader deposit/withdrawal regressions: **60 passed, 0 failed, 0 skipped**.

## Disposition of the nine original failures

| Original test | Remediation |
|---|---|
| coreRouteDoesNotFundPausedLeg | Core checks intake eligibility before transferring funds. |
| pausedNewLegPlannerExclusion | Router excludes paused and deposits-disabled strategies; unreadable flags fail closed. |
| disabledWeightedLegAvailability | Weighted routing normalizes over eligible legs instead of requiring their remaining weights to total 10000. |
| disablingFundedLegPreservesNav | Registered disabled positions remain in aggregate and strict NAV accounting. |
| externalPlanHonorsCap | Core validates cumulative per-strategy headroom before transfers, including duplicate entries. |
| publicDeploymentHonorsNewStrategyCap | Router clips planned allocation to current cap headroom; unused capital remains in Core. |
| publicCoreDepositDeployAndExit | Corrected the 2-USDC expectation: reserve-constrained deployment is a no-op. The separate 100-USDC deployment and recovery test remains. |
| scoredModeConfigured | Activation without a deployed scorer now rejects immediately. A deterministic scorer unit fixture verifies positive allocation and retained constraint shortfall. Production scorer deployment/configuration remains required if SCORED mode is chosen. |
| queueSettlementAfterLock | A time-warp does not refresh oracle feeds. Keep stale-input rejection; test settlement separately with an explicitly mocked fresh oracle. This fixture is not real oracle continuity evidence. |

## Source changes

- `multyr-core/src/core/modules/StrategyRouter.sol`: NAV inclusion, eligibility, weighted routing, cap headroom and scorer configuration validation. Scorer shortfalls stay in Core rather than being forced into the first leg.
- `multyr-core/src/core/modules/LiquidityOpsModule.sol`: validate the full intake plan before transfers, reject invalid transfer flags and zero legs, aggregate duplicate allocations against one cap.
- `multyr-periphery/script/planner/PlanDeposit.s.sol`: use a read-only call to the canonical router planner instead of maintaining divergent allocation arithmetic. Execution still revalidates the plan.
- `multyr-core/test/unit/core/StrategyRouter_MultiStrategyRegression.t.sol`: focused regression cases.

## Compatibility and deployment requirements

1. Router and LiquidityOps must be reviewed and deployed together: the module now requires `depositCapacity(address,uint256)`. Existing routers do not expose it.
2. Fork regression installs candidate runtime with `vm.etch` at existing addresses while preserving fork storage. This is a local test technique, **not** proof of an available production upgrade path. A replacement-router migration, roles, bindings, registered positions and module-selector changes need an independently reviewed deployment plan.
3. Intake eligibility now requires readable `paused()` and `depositsDisabled()` boolean getters. Current tested Lending strategies expose these. A strategy without them is ineligible until an explicit compatible integration is reviewed.
4. Disabled registered positions now remain in NAV. Unreadable valuations fail strict NAV validation even for disabled positions. Correctly draining or retiring such positions is an operational dependency; disabling does not erase liabilities or assets.
5. Ordinary redemption eligibility is unchanged; disabled positions remain recoverable through the existing force-exit path, tested separately. This patch does not establish every ordinary withdrawal path for disabled strategies.
6. Some admin-validation reverts use custom errors (`ZeroAddress`, `InvalidConfiguration`, `InvalidScorer`, `InvalidScorePlan`) to keep runtime below the deployment size limit. The underlying address and numeric limits are preserved.
7. Priority allocation retains excess capital when the chosen leg has insufficient headroom; it does not automatically redistribute that residual. Weighted allocation likewise retains cap-constrained residuals.
8. This package does not certify all rebalance paths, individual Aave/Morpho/Fluid lifecycles, historical index reconciliation, independent keeper continuity, or mainnet readiness. It addresses the recorded failures and the added regression cases.

## Reproduce

From the workspace root:

```sh
/Users/warlock/.foundry/bin/forge test --root multyr-core --match-contract 'StrategyRouter_(MultiStrategyRegression|Allowlist)|RouterRebalanceGuard'
python3 multi-strategy-fixes-20261101/prepare.py
python3 multi-strategy-fixes-20261101/run.py
```

`prepare.py` copies freshly built candidate runtime into the snapshot test fixtures and constructs the patched test suite without modifying the original test file. `run.py` reads the existing authorized RPC configuration privately; it does not use production wallet keys or broadcast transactions. It requires network access to the pinned fork. `additional-tests.txt` contains additional local fork tests. The original deterministic deployment address output can be regenerated by the fixture, but these addresses are fork-only.

Check the final result inventory and bytecode hashes in `verification.json`, and full logs in `unit.log`, `forge.log`, and `planner-build.log`. Do not use passing regression totals as burn volume or accepted clean time.
