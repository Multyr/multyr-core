// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Events {
    event DepositFeeParamsSet(uint16 depositFeeBps, uint16 withdrawFeeBps, address treasury);
    event PerfParamsSet(uint256 perfRateX, uint64 minCrystallizeInterval);
    event Crystallized(uint256 oldHwm, uint256 newHwm, uint256 feeAssets);
    event ClaimRequested(
        uint256 indexed claimId, address indexed user, uint256 shares, bool immediate
    );
    event ClaimCancelled(uint256 indexed claimId, address indexed user);
    event ClaimSettled(uint256 indexed claimId, address indexed user, uint256 netAssets);
    event DepositFeeTaken(address indexed sender, uint256 assetsFee, uint256 sharesToTreasury);
    event DepositForExecuted(
        address indexed payer, address indexed receiver, uint256 assets, uint256 shares
    );
    event WithdrawFeeTaken(address indexed sender, uint256 assetsFee, uint256 sharesToTreasury);
    event ForceExitPenaltyTaken(address indexed sender, uint256 penaltyAssets, uint256 penaltyShares);
    event PerfFeeMinted(
        uint256 hwmBefore, uint256 ppsBefore, uint256 sharesMinted, uint256 ppsAfter
    );
    event FeeParamsUpdated(uint16 depositFeeBps, uint16 withdrawFeeBps, address treasury);
    event PerfParamsUpdated(uint256 perfRateX, uint64 minInterval);

    event ClaimQueued(uint256 indexed claimId);
    event ClaimDequeued(uint256 indexed claimId);
    event QueueWarmRefillFailed(uint256 indexed claimId, uint256 requestedAmount, bytes reason);
    event QueueStrategyRedeemFailed(uint256 indexed claimId, uint256 requestedAmount, bytes reason);
    event QueueClaimSkippedInsufficientHot(uint256 indexed claimId, uint256 hotAvailable, uint256 grossNeeded);
    event QueuePrescanBoundHit(uint256 head, uint256 inspectedCount, uint256 eligibleCount, uint256 requiredHot, bool hitEarlyExit);
    event QueueGhostClaimPurged(uint256 indexed claimId);
    event SharesFrozen(address indexed user, uint256 shares, uint256 claimId);
    event SharesUnfrozen(address indexed user, uint256 shares, uint256 claimId);
    event RoutedToStrategy(address indexed strategy, uint256 amount, uint256 cashAfter);
    event Realized(uint256 amount);
    event ReserveTargetRestored(uint256 cashAfter);
    event EpochRolled(uint256 newEpochStart);

    // --- Param timelock (audit hardening) ---
    event FeeParamsSubmitted(
        uint16 depositFeeBps, uint16 withdrawFeeBps, address treasury, uint64 eta
    );
    event FeeParamsAccepted(uint16 depositFeeBps, uint16 withdrawFeeBps, address treasury);
    event FeeParamsRevoked();
    event PerfParamsSubmitted(uint256 perfRateX, uint64 minInterval, uint64 eta);
    event PerfParamsAccepted(uint256 perfRateX, uint64 minInterval);
    event PerfParamsRevoked();
    event OpsReserveTargetSubmitted(uint16 bps, uint64 eta);
    event OpsReserveTargetAccepted(uint16 bps);
    event OpsReserveTargetRevoked();
    event MinDelaySubmitted(uint64 newDelay, uint64 eta);
    event MinDelayAccepted(uint64 newDelay);
    event MinDelayRevoked();

    // --- Pause events ---
    event DepositsPaused();
    event DepositsUnpaused();
    event WithdrawalsPaused();
    event WithdrawalsUnpaused();

    // --- Withdrawal rate limiting ---
    event MaxWithdrawalPerBlockUpdated(uint256 limit);
    event MaxWithdrawalPerTxUpdated(uint256 limit);
    event MinClaimAmountUpdated(uint256 minimum);
    event CapPerEpochBpsUpdated(uint16 bps);

    // --- B5: Dynamic withdrawal caps ---
    event DynamicCapConfigured(uint16 minBps, uint16 maxBps, uint256 threshold, bool enabled);

    // --- Queue anti-spam (A4: Audit Fix) ---
    event QueueAntiSpamConfigured(
        uint8 maxClaimsPerEpoch, uint64 cooldownSeconds, uint64 epochDuration
    );

    // --- Circuit breaker ---
    event CircuitBreakerConfigured(uint16 thresholdBps, uint64 snapshotInterval);
    event CircuitBreakerTriggered(uint256 lastTVL, uint256 currentTVL, uint256 dropBps);
    event TVLSnapshotUpdated(uint256 tvl, uint64 timestamp);

    // --- Guardian ---
    event GuardianPauseActivated(address indexed guardian, uint256 timestamp);
    event GuardianUpdated(address indexed newGuardian);

    // --- Deploy to Strategy ---
    event DeployPlanned(uint256 surplus, uint256 legs);
    event DeployExecuted(uint256 totalDeployed, uint256 legsSucceeded, uint256 legsAttempted);
    event DeploySkipped(uint8 reason); // 0=no-bm-or-router, 1=hot-below-reserve, 2=zero-surplus, 3=empty-plan
    event RealizedForQueue(uint256 target, uint256 got);
    event StrategiesRebalanced(uint256 totalMoved, uint256 strategyCount);

    // V10 — Portfolio-grade allocation engine (Correction #13)
    event StrategiesRebalancePlanBuilt(
        uint256 totalMoveUsd, uint16 driftBps, int16 deltaAPYBps,
        uint16 aggregateConfidence, bool isSafetyPlan, uint16 safetyReasonCode
    );
    event RebalanceGuardEvaluated(
        bool proceed, uint8 reasonCode,
        int256 netBenefitBeforeScale, int256 netBenefitAfterScale,
        uint16 allowedMoveBps, uint8 regime
    );
    event ExecutionMemoryRecordFailed(address indexed strategy);
    event RebalancePolicyUpdated(address policy);
    event RebalanceGuardUpdated(address guard);
    event ExecutionMemoryUpdated(address em);
    event StrictExecutionMemorySet(bool strict);

    // --- Ops high-level ---
    event Rebalanced(address indexed from, address indexed to, uint256 amount);
    event EmergencyDrainStarted();
    event EmergencyDrainCompleted(uint256 totalRecovered);
    event LiquidityOpLocked();
    event LiquidityOpUnlocked();

    // --- PPS snapshot ---
    event VaultPpsSnapshot(uint64 timestamp, uint256 totalAssets, uint256 totalSupply, uint256 pps);

    // --- Fee Collector ---
    event FeeCollectorSet(address indexed feeCollector);

    // --- Health Registry (B3: Audit Fix) ---
    event HealthRegistrySetInVault(address indexed registry);

    // --- IParamsProvider / Guardrails (Phase 1 Complete) ---
    event OracleSet(address indexed oracle);
    event BatchGuardrailsUpdated(uint8 maxActions, uint16 maxNavDelta, uint256 staleness);
    event VaultDepositCapUpdated(uint256 cap);
    event AdapterAllowedUpdated(address indexed adapter, bool allowed);
    event AdapterCapUpdated(address indexed adapter, uint256 cap);

    // --- NAV Smoothing ---
    event NavSmoothUpdated(uint256 navReal, uint256 navSmooth, uint256 timestamp);

    // --- External Call Failures (Security Logging) ---
    event ExternalCallFailed(address indexed target, string functionName, bytes reason);
    event IncentivesOnDepositFailed(address indexed receiver, bytes reason);
    event IncentivesOnExitFailed(address indexed user, bytes reason);

    // --- Diamond-lite routing events ---
    event ModuleSet(bytes4 indexed selector, address indexed module, uint8 role);
    event ModulesBatchSet(uint256 count);
    event RoleSet(bytes4 indexed selector, uint8 role);
    event RoutingFrozen();

    // --- Pause events (Diamond-lite) ---
    event AllPaused();
    event AllUnpaused();

    // --- Ownership events (Diamond-lite) ---
    event OwnershipTransferInitiated(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- Component update events (Diamond-lite) ---
    event ParamsProviderUpdated(address indexed newParams);
    event BufferManagerUpdated(address indexed newBuffer);
    event StrategyRouterUpdated(address indexed newRouter);
    event HealthRegistryUpdated(address indexed newRegistry);
    event IncentivesUpdated(address indexed newIncentives);
    event FeeCollectorUpdated(address indexed newCollector);
    event VetoerUpdated(address indexed newVetoer);
    event ParamsFrozen();

    // --- Ecosystem batch config (Factory deployment) ---
    event EcosystemConfigured(
        address indexed bufferManager,
        address indexed strategyRouter,
        address healthRegistry,
        address incentives,
        address guardian,
        address vetoer
    );

    // --- Factory deployment events ---
    event VaultCreated(
        address indexed vault,
        address indexed asset,
        address owner,
        address feeCollector,
        string name,
        string symbol
    );
    event VaultRoutingConfigured(address indexed vault, address queueModule, address adminModule);
    event VaultProductionReady(address indexed vault);
    event VaultDeprecated(address indexed vault);
    event VaultStatusChanged(address indexed vault, string status, string note);
    event VaultRemoved(address indexed vault);

    // --- Component timelock events ---
    event ComponentsTimelockEnabled();
    event BufferManagerSubmitted(address indexed newBuffer, uint64 eta);
    event BufferManagerAccepted(address indexed newBuffer);
    event BufferManagerRevoked();
    event RouterSubmitted(address indexed newRouter, uint64 eta);
    event RouterAccepted(address indexed newRouter);
    event RouterRevoked();

    // --- Warm adapter approval events ---
    event WarmAdapterApproved(address indexed adapter);
    event WarmAdapterRevoked(address indexed adapter);

    // --- Selector Registry & System Seal events ---
    event SelectorRegistrySet(address indexed registry);
    event AuthorizedSealerSet(address indexed sealer);
    event SystemSealed(address indexed sealer, bytes32 configHash, uint256 timestamp);

    // --- Module Authorization events ---
    event ModuleAuthorized(address indexed module, bool authorized);

    // --- Exit Engine events (ExitEngineLib architecture) ---
    event InstantExit(
        address indexed user, uint256 shares, uint256 netAssets, uint256 feeShares
    );
    event ForceExit(
        address indexed user, uint256 shares, uint256 netAssets, uint256 feeShares
    );
    event FeePaid(
        address indexed user, address indexed feeCollector, uint256 feeShares
    );
    event QueueClaimSkippedEscrowUnderflow(
        uint256 indexed claimId, address indexed user, uint256 sharesRequested, uint256 escrowBalance
    );
    event QueueSizeWarning(uint256 queueLength);

    // --- IncentivesEngine v2 ---
    event IncentivesEngineUpdated(address indexed newEngine);
    event RewardsPayoutManagerUpdated(address indexed newManager);
    event RewardSharesMinted(address indexed user, uint256 usdcEquivalent, uint256 shares);

    // --- Dead Deposit (Inflation Attack Hardening) ---
    event DeadDepositSeeded(uint256 assets, uint256 shares, address indexed dead);

    // --- Immediate Exit Penalty ---
    event ImmediateExitPenaltyApplied(
        address indexed user, uint256 penaltyAssets, uint256 penaltyShares
    );
    event ImmediateExitPenaltyUpdated(uint16 oldBps, uint16 newBps);

    // --- Force Exit Penalty (Guaranteed Exit) ---
    /// @notice Emitted when force exit penalty is applied during forceWithdraw
    /// @dev Only emits shares (no PPS-dependent assets to avoid post-liquidity-sourcing inaccuracy)
    event ForceExitPenaltyApplied(address indexed user, uint256 penaltyShares);
    /// @notice Emitted when force exit penalty parameter is updated via governance
    event ForceExitPenaltyUpdated(uint16 oldBps, uint16 newBps);
    /// @notice Emitted when forceWithdraw operation completes successfully
    event ForceWithdrawExecuted(
        address indexed caller,
        address indexed owner_,
        address receiver,
        uint256 assets,
        uint256 sharesSpent
    );

    // ── FixedMaturity lifecycle events ────────────────────────────────────────

    /// @notice Vault mode switched to FixedMaturity (mode=1)
    event VaultModeConfigured(uint8 mode);

    /// @notice FixedMaturity parameters set (one-shot)
    event FixedMaturityConfigured(
        uint64 maturityTs,
        uint256 minFundingAssets,
        uint256 targetFundingAssets,
        uint64 fundingDeadlineTs,
        bool autoCloseFundingOnTarget,
        bool instantEnabledAfterMaturity,
        uint256 preMaturityForceExitPenaltyBps
    );

    /// @notice Auto-close triggered when funding target reached during deposit
    event FundingAutoClosedAtTarget(uint256 netFundedAssets, uint256 targetFundingAssets);

    /// @notice Funding phase failed — deadline passed with net < min
    event FundingFailed(uint256 netFundedAssets, uint256 minFundingAssets, uint64 fundingDeadlineTs);

    /// @notice Transition Funding -> Starting committed
    event FixedMaturityCycleStarted(uint64 startingTs, uint256 committedAssets, uint256 retainedHotBuffer);

    /// @notice Transition Starting -> Active, capital deployed to strategy
    event FixedMaturityCycleActivated(uint64 startTs, uint64 maturityTs, uint256 committedAssets);

    /// @notice Maturity reached; final performance fee applied
    event FixedMaturityMatured(uint64 maturityTs);

    /// @notice Cycle closed (terminal state)
    event FixedMaturityClosed();

    /// @notice User claimed refund in FundingFailed state
    event FixedMaturityRefundClaimed(address indexed user, uint256 shares, uint256 assetsReturned);

    /// @notice Final performance fee applied at maturity
    event FixedMaturityFinalPerformanceFeeApplied(uint256 grossProfit, uint256 performanceFeeAssets);

    // ── FixedMaturityVaultUpkeep events ──────────────────────────────────────

    event FixedMaturityUpkeepChecked(uint8 indexed op, bool upkeepNeeded, uint8 indexed vaultState);
    event FixedMaturityUpkeepPerformed(uint8 indexed op, uint8 indexed stateBefore, uint8 indexed stateAfter);
    event FixedMaturityUpkeepNoOp(uint8 indexed op, uint8 indexed vaultState);
    event FixedMaturityUpkeepErrored(uint8 indexed op, bytes reason);
}
