# Automatic claim settlement operations

Automatic settlement is a required protocol service. Deploy and register
`ClaimSettlementUpkeep` for the intended vault, verify its target and governance owner,
set scan/batch limits, fund the registration and monitor it before accepting real TVL.
Do not infer that registration is complete from deployment of the contract alone.

## Execution policy

Both upkeep entrypoints return without scanning if `outstandingClaimCount()` or
`fundedOutstandingClaimCount()` is zero. Open and Closed-but-unfunded claims cannot justify
maintenance. The funded counter includes zero-recovery claims, which still need their
accounting settled. Drained epochs are skipped. Large histories with no funded work do
not generate periodic maintenance transactions.

A funded backlog can require bounded cursor-maintenance transactions. The scan wraps and
revisits epochs funded out of order. A failed batch retries claims individually. Failed
recipients get a one-hour retry delay; unsuccessful/maintenance runs have a one-minute
cooldown. Excluded or delayed claims remain outstanding, so funded-work gating alone is
not a promise of zero maintenance cost while such claims exist. Monitor and investigate
persistent failures rather than treating retry as a payment guarantee.

The counter requires the matching queue module and public selector registration. A new
vault populates it through funding/settlement. A live module upgrade with existing funded
claims requires a separately reviewed counter initialization; do not install the getter
alone and assume its default zero represents an empty queue.

## Manual fallback

`claimEpochAssets(epochId, claimId)` and `batchClaimEpochAssets(epochId, claimIds)` remain
available to the recorded owner. Keeper exclusion, retry delay, lack of LINK and downtime
do not disable these functions. Both automatic and manual claims respect the dedicated
funded-claim breaker. Ordinary pauses do not set that breaker.

Payment always goes to the recorded claim owner. A token restriction or receiver-specific
transfer failure cannot be forced or redirected by the keeper, and manual claiming does
not bypass the same transfer restriction. Failure leaves the claim unsettled and its
reserve intact. After the restriction is resolved, the owner can claim or automation can
retry. A settled claim cannot be paid twice.

## LINK budget and gas sizing

For a LINK-funded registration, on-chain upkeep executions debit the protocol's upkeep
LINK balance. Billing includes execution gas, registry overhead and the network premium;
failed-claim and maintenance executions also cost money. Off-chain checks have no separate
execution charge. Verify the chosen registry's current parameters at deployment.
See [Chainlink billing](https://docs.chain.link/chainlink-automation/overview/automation-economics).

This adds protocol cost for automatically settled queued withdrawals, not a distinct
keeper transaction for every withdrawal: batches amortize overhead, instant withdrawals
settle in the user's request transaction, and self-claims are submitted by users.

Before real TVL, measure receipts or fork simulations through the intended registry for:

| Scenario | Budget purpose |
|---|---|
| One funded claim | Low-volume cost per withdrawal |
| Full default batch of 20 | Batch amortization and gas limit |
| Sparse funded backlog across a 200-probe page | Cursor-maintenance overhead |
| Batch failure followed by 20 individual attempts | Failure-path gas ceiling |
| Zero recovery / manual settlement race | Accounting-only and stale check paths |
| Fully settled history and unfunded-only history | Must produce no scheduled upkeep |

Use the registry's payment formula with measured execution gas, chain gas-price scenarios,
LINK/native conversion, premium, overhead and any chain-specific data fees. Model monthly
cost as the sum of successful, retry and maintenance executions; divide by paid claims
for cost per withdrawal. Size the gas limit for the failure path, and alerts/refill budget
for peak demand and gas spikes. Test a funded claim can be paid with the chosen limit.

Local reproducible contract-level measurement:

```sh
forge test --match-path test/unit/automation/ClaimSettlementUpkeep.t.sol --gas-report
```

The local 20-test automation run observed `performUpkeep` at 40,718–543,471 gas
across 78 calls (including deliberately invoked no-ops), and `checkUpkeep` at
17,427–200,997 gas across 83 calls. These are observations of that test workload, not
upper bounds: it does not exercise a full 20-recipient failure batch.

The local harness uses a mock token, warmed state and direct contract calls; its gas report
is a regression baseline, not a production LINK quote or registry gas-limit certification.
Network/registry configuration and expected withdrawals per day are deployment inputs.

## Monitoring and release order

Alert on low LINK, stalled funded counts, repeated `ClaimSettlementFailed`, funded-claim
pauses and long funding delays. Track successful claims per transaction, gas per paid
claim, maintenance executions and retry frequency.

Land #19's funding/docs work first. After #19 is merged into main, rebase #20 on that main
and rerun queue, automation, selector/role and integration tests before release. No merge,
rebase, deployment or registration is performed by this runbook.
