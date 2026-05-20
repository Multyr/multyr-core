// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Parametri bloccati (gi├á usato)
error ParamsFrozen();

// Stato/ruoli
error Paused();
error NotOwner();

// Validazione input/flussi
error ZeroAmount();
error NotClaimOwner();
error AlreadySettled();
error RecipientFrozen();
error WithdrawalLimitExceeded();
error SharesLocked();

// Component timelock errors
error ComponentsTimelocked();
error ComponentsNotTimelocked();
error NotPending();

// ── FixedMaturity Module errors ───────────────────────────────────────────────
error InvalidVaultMode();
error InvalidVaultState();
error InvalidStateTransition();
error FixedMaturityNotConfigured();
error AlreadyConfigured();
error FixedMaturityAlreadyStarted();
error MaturityNotReached();
error FundingBelowMinimumThreshold();
error FundingStillOpen();
error FundingAlreadyFailed();
error NotFundingFailed();
error ZeroCommittedAssets();
error FinalPerformanceFeeAlreadyApplied();
error RefundNotAvailable();

// ── FixedMaturityVaultUpkeep errors ──────────────────────────────────────────
error InvalidFixedMaturityVault();
error FixedMaturityUnsupportedState();
error FixedMaturityAutomationStateMismatch();
error FixedMaturityAutomationDisabledForMode();
error UnknownOperation();
error FundingReadinessNotMet();
error SettlementNotRequired();
error CloseNotAllowedWithPendingShares();
