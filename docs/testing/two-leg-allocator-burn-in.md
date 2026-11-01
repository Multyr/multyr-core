# Two-leg allocator burn-in: predeclared acceptance criteria

Status: PRE-FLIGHT ONLY. No new contracts deployed, capital moved, or intake mode changed.
The measured clock starts only after configuration, observability and the negative control pass. Record the actual UTC start block/time; do not count setup or keeper downtime as burn-in.

## Blocking checks

- Local source inspection on 2026-10-13 found an additional execution-path blocker: `multyr-periphery/script/planner/PlanDeposit.s.sol` branches only for PRIORITY and WEIGHTED. With SCORED and enabled strategies, it leaves the output arrays zero-filled and can report `valid=true` with zero total. Identify the actual deployed keeper/planner and prove its SCORED support before switching modes. The router's `planDeposit` is explicitly deprecated for production use; success in that view alone does not establish keeper support.
- Validation limitation: the targeted existing setter regression (`forge test --match-test test_setRebalanceParams_reverts_minAdapters_too_low --offline`) could not run because `forge` is not on this shell's PATH. Findings below are source inspection, not a completed fork or live test. Idle allocation accepts one enabled candidate in `StrategyAllocCalcModule.execSelectAllocation`, subject to eligibility and headroom; this must not be confused with rebalance support.
- Prove single-adapter deposit, idle deployment, plan creation, execution and withdrawal on a fork of the chosen deployment source. The current setter rejects minAdaptersActive=1; the constructor directly assigns it. Constructor acceptance alone is not support. Until full lifecycle passes, use leg B = Aave + one independently verified non-Aave venue, and remove BOTH venues from leg A.
- Verify venue disjointness through underlying pools/markets, including nested exposure (e.g. a curated vault lending into a venue used by the other leg). Adapter names alone are insufficient. Account for the core warm buffer's venue separately.
- Pin source commits/patches and compiler artifacts; current checkout must not be assumed identical to the October 9 deployment.
- Reproduce and address SCORED remainder cap bypass before live deployment. Preserve cap-rejected amounts as unallocated, or redistribute only to verified remaining headroom. Record scorer outputs, remainder, recipient and final executed allocation. Single-eligible bypass also needs cap enforcement verification.
- Establish intended relative-cap denominator. Current StrategyScorer reads strategy.totalAssets(), not venue-wide liquidity: an empty strategy with nonzero relativeCapBps has zero relative headroom. Do not conceal this via the remainder path.
- Confirm the keeper observes and executes score-driven cross-strategy rebalances, not merely intake or each lending instance's internal adapter rebalance.
- Explicit SCORED mode and nonzero scorer; chosen vaultDepositCap; nonzero per-strategy caps; explicit targetHotBps/minHotBps and warm venue; sequencer feed plus operational/grace-period checks; exact production fee and cost/gate values. Read back all settings at a pinned block.
- No SystemSealer calls. Keep this isolated from production vaults. Budget, vault cap and buffer values must be recorded before funding.
- Switching intake mode changes subsequent allocation planning only: existing positions remain until a separately executed deposit/rebalance/withdrawal moves them.

## Scenarios, executed in order

1. Negative control: register only leg A. All deployable capital goes to A subject to explicit caps and buffers; any refused capital stays accounted for as idle. No assets reach B. Complete deposit -> adapter deployment -> withdrawal request -> settlement -> user receipt. Reconcile principal, fees, gas, slippage and remaining dust; zero unexplained loss. Failure stops subsequent scenarios.
2. Both legs, natural scores: observe at least a full gate/cooldown interval and a daily observation window. Recompute every allocation from contemporaneous scores, eligibility, caps and buffers. No executed rebalance while the gate says false. Nonzero allocations to both are required to measure a split; legitimate saturation/zero scores are reported as an inconclusive diversification test, not forced into a pass.
3. Controlled divergence: on a fork first, modify one documented leg-A adapter eligibility input; never falsify a live yield/oracle. Hold other inputs fixed in replay. Before cap saturation, increasing A-minus-B score must not reduce A's target share. Existing holdings should move only when benefit, drift, cooldown and liquidity gates pass. Record blocked decisions and reasons; observed correlation alone cannot establish causation.
4. Degradation: separately assert (a) no new intake into degraded leg and (b) exit via the actual underlying withdrawal/queue route succeeds within its predeclared liquidity/settlement bounds. Never disable exits along with intake. Reconcile recovered amounts net of declared fees/costs. Stop if recovery bounds are exceeded.

Before each scenario, save a machine-readable parameter/block snapshot, exact perturbation, amounts, rounding tolerance in raw USDC units, observation duration and expected gate outputs. Do not choose tolerances after outcomes are known.

## Daily evidence and accounting

For each leg: allocated assets/share; raw and adjusted scores and differential; APY inputs and timestamps; health, flags, cap/headroom, cash, confidence; actual vs target allocation; every intake/rebalance decision including skipped actions, gate thresholds, cooldowns and reason; transaction/receipt and block. Capture remainder path separately. Use block-pinned calls and traces/replay when events omit inputs.

Measure turnover as gross absolute movements and also one-way moved capital (avoid double-counting exits plus entries). Costs: actual gas including L1 component converted to USDC at transaction time; execution slippage versus contemporaneous expected proceeds; protocol/withdrawal fees separately. Report gross and net returns, adjusting for external flows and avoiding double-counting fees already embedded in NAV.

Benchmarks on identical capital, cash flows, buffers, fees and observation times: static 50/50; 100% A; 100% B; best fixed leg selected ex post. Report an omniscient switching benchmark separately if used; it is not the same as the best fixed leg. Headline: allocator net return minus static-50/50 net return, in USDC and basis points.

Return correlation uses aligned flow-adjusted interval returns with sample count and window disclosed. >0.9 means little demonstrated diversification; constant/near-zero variance or too few observations means undefined/inconclusive. Four daily observations cannot establish reliable correlation. Retain higher-frequency observations and extend the sample as necessary.

Underperformance is evidence for investigation, not proof of mistuned thresholds: distinguish costs, score quality, caps, liquidity, insufficient observations and market regime before changing gates.
