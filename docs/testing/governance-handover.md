# Setup followed by governance handover

The October 2026 deployment uses the independent Governor, Guardian, Vetoer,
Treasury, Ops, Safety Reserve and Security Approver addresses in `multyr-core/.env`.
Do not replace these addresses with the deployer.

`DeployCoreSystem` deploys setup-owned components and configures the intended
Guardian/Vetoer/Security Approver directly. `DEFER_CORE_HANDOVER=true` retains
administration only while the strategy is being deployed and registered.
The deployment sets `INITIAL_STRATEGY_ALLOWLIST_DELAY=300`; each new proposal must
wait five minutes. The router still defaults to two days outside this deployment
profile; governance can raise the configured delay after initial testing.

`DeployUsdcLendingStrategy` configures all seven adapters, providers, registry and
upkeep, grants Governor administration and Guardian/KMS keeper permissions, then
removes the deployer's strategy and adapter roles. ClaimSettlementUpkeep transfers
its owner to the Governor immediately after configuration.

`CompleteCoreHandover` finishes allowlist execution/registration and caps, restores
the 600-second warm-NAV interval, optionally activates testing, and transfers
GlobalConfig and the supporting components to the Governor. It nominates the
Governor for four two-step transfers:

1. CoreVault: `acceptOwnerTransfer()`.
2. FeeCollector: `acceptGovernorTransfer()`.
3. VaultFactory: `acceptOwnership()`.
4. RecoveryGate: `acceptRootTimelockTransfer()`.

The Governor Safe must execute these calls. The deployer remains the current
controller on those four contracts until acceptance; a pending transfer is not a
completed handover. The deployment report and Safe transaction bundle record this
state explicitly. RecoveryGate root acceptance cancels outstanding predecessor
recovery/approver-change proposals and preserves the recovery delay, cooldown and
independent approver.

Unsealing/freezing and recovery-policy timing are separate from this setup. The
five-minute allowlist delay does not shorten the 21-day recovery delay. Historical
deployments and their funds are not migrated by deploying a new address book.
