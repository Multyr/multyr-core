# Sprint Deliverables

Final review materials for the Multyr Core sprint.

## Must Have

- [Risk analysis](risk-analysis.md): all sprint findings with severity, exploit
  scenario, fix/resolution, and residual risk.
- [Architecture understanding](architecture-understanding.md): complete system
  walkthrough, module boundaries, security invariants, and review order.
- [Complete understanding](complete-understanding.md): deeper design rationale
  for routing, storage, governance, liquidity tiers, sealer, and periphery.

## Nice To Have

- [Flow diagrams](flow-diagrams.md): Mermaid diagrams for routing, deposits,
  exits, strategy deployment, governance, and sealing.
- [DepositRouter with Permit2](deposit-router-permit2.md): recommended periphery
  payer model and integration notes.

## Supporting Notes

- [Suggested improvements](suggested-improvements.md): completed sprint fixes
  plus remaining production hardening items.

## Sprint POCs

The corresponding POC/regression tests live in `test/sprint-test/`:

- `DepositFor_UnauthorizedPayer_POC.t.sol`
- `ForceWithdrawAll_SlippagePOC.t.sol`
- `SystemSealer_TimestampHash_POC.t.sol`
- `HWM_Drawdown_POC.t.sol`
- `DeployToStrategiesWithPlan_Drain.t.sol`
- `AdminModule_GovernanceBypass_POC.t.sol`
