// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AdminModule } from "../modules/AdminModule.sol";
import { QueueModule } from "../modules/QueueModule.sol";
import { LiquidityOpsModule } from "../modules/LiquidityOpsModule.sol";
import { FixedMaturityModule } from "../modules/FixedMaturityModule.sol";

/**
 * @title SelectorRegistry
 * @notice Immutable registry of selector-to-role mappings for CoreVault routing guardrails
 * @dev This contract serves as the SINGLE SOURCE OF TRUTH for which selectors require which roles.
 *      CoreVault.setModule/setModulesBatch MUST consult this registry to prevent misrouting attacks.
 *
 * SECURITY MODEL:
 * - Owner-critical selectors can ONLY be assigned ROLE_OWNER
 * - Public selectors can ONLY be assigned ROLE_PUBLIC
 * - Any attempt to assign wrong role to a registered selector reverts
 * - ALLOWLIST MODE (COMANDO #14): Unregistered selectors are REJECTED by requireKnownSelector()
 *   CoreVault should call requireKnownSelector() to block shadow/unknown selectors
 *
 * AUDIT NOTES:
 * - All selectors are computed at compile time (pure functions)
 * - No storage, no admin, no upgrades - fully immutable
 * - Gas efficient: uses switch statements for O(1) lookup
 */
contract SelectorRegistry {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ROLE CONSTANTS (must match CoreVault)
    // ═══════════════════════════════════════════════════════════════════════════════
    uint8 public constant ROLE_PUBLIC = 0;
    uint8 public constant ROLE_OWNER = 1;
    uint8 public constant ROLE_GUARDIAN = 2;
    uint8 public constant ROLE_OWNER_OR_GUARDIAN = 3;
    uint8 public constant ROLE_MODULE = 4;

    // Special value indicating selector is not registered (any role allowed)
    uint8 public constant ROLE_UNREGISTERED = 255;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error InvalidRoleForSelector(bytes4 selector, uint8 attemptedRole, uint8 requiredRole);
    error UnknownSelector(bytes4 selector);

    // ═══════════════════════════════════════════════════════════════════════════════
    // CORE QUERY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the required role for a selector
     * @param selector The function selector to query
     * @return role The required role (ROLE_UNREGISTERED if not in registry)
     */
    function getRequiredRole(bytes4 selector) public pure returns (uint8 role) {
        // ─────────────────────────────────────────────────────────────────────────
        // ADMINMODULE OWNER SELECTORS (26 total) - MUST BE ROLE_OWNER
        // ─────────────────────────────────────────────────────────────────────────

        // Fee params timelock
        if (selector == AdminModule.submitFeeParams.selector) return ROLE_OWNER;
        if (selector == AdminModule.acceptFeeParams.selector) return ROLE_OWNER;
        if (selector == AdminModule.revokeFeeParams.selector) return ROLE_OWNER;

        // Perf params timelock
        if (selector == AdminModule.submitPerfParams.selector) return ROLE_OWNER;
        if (selector == AdminModule.acceptPerfParams.selector) return ROLE_OWNER;
        if (selector == AdminModule.revokePerfParams.selector) return ROLE_OWNER;

        // Min delay timelock
        if (selector == AdminModule.submitMinDelay.selector) return ROLE_OWNER;
        if (selector == AdminModule.acceptMinDelay.selector) return ROLE_OWNER;
        if (selector == AdminModule.revokeMinDelay.selector) return ROLE_OWNER;

        // Component setters (CRITICAL - immediate effect)
        if (selector == AdminModule.setParams.selector) return ROLE_OWNER;
        if (selector == AdminModule.setBufferManager.selector) return ROLE_OWNER;
        if (selector == AdminModule.setRouter.selector) return ROLE_OWNER;
        if (selector == AdminModule.setHealthRegistry.selector) return ROLE_OWNER;
        if (selector == AdminModule.setIncentives.selector) return ROLE_OWNER;
        if (selector == AdminModule.setFeeCollector.selector) return ROLE_OWNER;
        if (selector == AdminModule.setVetoer.selector) return ROLE_OWNER;

        // Freeze/finalize (CRITICAL - irreversible)
        if (selector == AdminModule.freezeParams.selector) return ROLE_OWNER;
        if (selector == AdminModule.setEcosystem.selector) return ROLE_OWNER;

        // Component timelock functions
        if (selector == AdminModule.enableComponentsTimelock.selector) return ROLE_OWNER;
        if (selector == AdminModule.submitBufferManager.selector) return ROLE_OWNER;
        if (selector == AdminModule.acceptBufferManager.selector) return ROLE_OWNER;
        if (selector == AdminModule.revokeBufferManager.selector) return ROLE_OWNER;
        if (selector == AdminModule.submitRouter.selector) return ROLE_OWNER;
        if (selector == AdminModule.acceptRouter.selector) return ROLE_OWNER;
        if (selector == AdminModule.revokeRouter.selector) return ROLE_OWNER;

        // Dead deposit (inflation attack hardening)
        if (selector == AdminModule.seedDeadDeposit.selector) return ROLE_OWNER;
        // Initial fees + perf params (one-shot setup)
        if (selector == AdminModule.setInitialFees.selector) return ROLE_OWNER;
        if (selector == AdminModule.setInitialPerfParams.selector) return ROLE_OWNER;
        // IncentivesEngine v2 + RewardsPayoutManager
        if (selector == AdminModule.setIncentivesEngine.selector) return ROLE_OWNER;
        if (selector == AdminModule.setRewardsPayoutManager.selector) return ROLE_OWNER;
        // V10 Portfolio-Grade Allocation Engine (Policy + Guard + ExecutionMemory)
        if (selector == AdminModule.setRebalancePolicy.selector) return ROLE_OWNER;
        if (selector == AdminModule.setRebalanceGuard.selector) return ROLE_OWNER;
        if (selector == AdminModule.setExecutionMemory.selector) return ROLE_OWNER;
        if (selector == AdminModule.setStrictExecutionMemory.selector) return ROLE_OWNER;

        // ─────────────────────────────────────────────────────────────────────────
        // ADMINMODULE VIEW SELECTORS (14 total) - MUST BE ROLE_PUBLIC
        // ─────────────────────────────────────────────────────────────────────────
        if (selector == AdminModule.getPendingFeeParams.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getPendingPerfParams.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getPendingMinDelay.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getFeeParams.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getPerfParams.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getMinDelay.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getEcosystem.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.isComponentsTimelocked.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getPendingBufferManager.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getPendingRouter.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.isDeadDepositDone.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getImmediateExitPenalty.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.isFeesInitialized.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.getForceExitPenalty.selector) return ROLE_PUBLIC;
        if (selector == AdminModule.isPerfInitialized.selector) return ROLE_PUBLIC;

        // ─────────────────────────────────────────────────────────────────────────
        // QUEUEMODULE WRITE SELECTORS (5 total) - MUST BE ROLE_PUBLIC
        // ─────────────────────────────────────────────────────────────────────────
        if (selector == QueueModule.requestClaim.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.cancelClaim.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.processQueuedRedemptions.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.settleFeesAndProcessQueue.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.endEpochCrystallize.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.compactQueue.selector) return ROLE_PUBLIC;

        // ─────────────────────────────────────────────────────────────────────────
        // QUEUEMODULE VIEW SELECTORS (3 total) - MUST BE ROLE_PUBLIC
        // ─────────────────────────────────────────────────────────────────────────
        if (selector == QueueModule.nextClaimId.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.queueLength.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.pendingShares.selector) return ROLE_PUBLIC;

        // ─────────────────────────────────────────────────────────────────────────
        // ERC4626MODULE SELECTORS (10 total) - MUST BE ROLE_PUBLIC
        // Standard ERC4626 user-facing functions routed via delegatecall
        // ─────────────────────────────────────────────────────────────────────────

        // Standard ERC4626
        if (selector == 0x6e553f65) return ROLE_PUBLIC; // deposit(uint256,address)
        if (selector == bytes4(keccak256("depositFor(uint256,address)"))) return ROLE_PUBLIC; // depositFor(uint256,address)
        if (selector == 0x94bf804d) return ROLE_PUBLIC; // mint(uint256,address)
        if (selector == 0xb460af94) return ROLE_PUBLIC; // withdraw(uint256,address,address)
        if (selector == 0xba087652) return ROLE_PUBLIC; // redeem(uint256,address,address)

        // Slippage-protected overloads
        if (selector == 0x0efe6a8b) return ROLE_PUBLIC; // deposit(uint256,address,uint256)
        if (selector == 0xc6e6f592) return ROLE_PUBLIC; // redeem(uint256,address,address,uint256)
        if (selector == 0x2a1f2a0c) return ROLE_PUBLIC; // mint(uint256,address,uint256)
        if (selector == 0x9a0e7d66) return ROLE_PUBLIC; // withdraw(uint256,address,address,uint256)

        // Force withdraw (guaranteed exit)
        if (selector == 0x439fdeb4) return ROLE_PUBLIC; // forceWithdraw(uint256,address,address,(address,uint256)[],uint256)

        // ─────────────────────────────────────────────────────────────────────────
        // LIQUIDITYOPSMODULE SELECTORS
        // deployToStrategies / canDeploy / realize* / rebalance* are keeper-public.
        // deployToStrategiesWithPlan accepts a caller-supplied allocation plan and
        // must be ROLE_OWNER_OR_GUARDIAN -- even with strategy address validation a
        // permissionless caller could manipulate which registered strategies receive
        // capital and in what proportion.
        // ─────────────────────────────────────────────────────────────────────────
        if (selector == LiquidityOpsModule.canDeploy.selector) return ROLE_PUBLIC;
        if (selector == LiquidityOpsModule.deployToStrategies.selector) return ROLE_PUBLIC;
        if (selector == LiquidityOpsModule.deployToStrategiesWithPlan.selector) return ROLE_OWNER_OR_GUARDIAN;
        if (selector == LiquidityOpsModule.realizeForQueue.selector) return ROLE_PUBLIC;
        if (selector == LiquidityOpsModule.realizeForReserveAndOps.selector) return ROLE_PUBLIC;
        if (selector == LiquidityOpsModule.canRebalanceStrategies.selector) return ROLE_PUBLIC;
        if (selector == LiquidityOpsModule.rebalanceStrategies.selector) return ROLE_PUBLIC;

        // Queue module views
        if (selector == QueueModule.requiredHotForBatch.selector) return ROLE_PUBLIC;
        if (selector == QueueModule.settlePreview.selector) return ROLE_PUBLIC;

        // ─────────────────────────────────────────────────────────────────────────
        // FIXEDMATURITYMODULE GOVERNANCE SELECTORS - MUST BE ROLE_OWNER
        // ─────────────────────────────────────────────────────────────────────────
        if (selector == FixedMaturityModule.setVaultModeFixedMaturity.selector) return ROLE_OWNER;
        if (selector == FixedMaturityModule.configureFixedMaturity.selector) return ROLE_OWNER;
        if (selector == FixedMaturityModule.startFixedMaturityCycle.selector) return ROLE_OWNER;
        if (selector == FixedMaturityModule.activateFixedMaturityCycle.selector) return ROLE_OWNER;
        if (selector == FixedMaturityModule.closeFixedMaturityCycle.selector) return ROLE_OWNER;
        if (selector == FixedMaturityModule.recallFixedTermCapital.selector) return ROLE_OWNER;

        // ─────────────────────────────────────────────────────────────────────────
        // FIXEDMATURITYMODULE PUBLIC SELECTORS - MUST BE ROLE_PUBLIC
        // ─────────────────────────────────────────────────────────────────────────
        if (selector == FixedMaturityModule.markMatured.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.markFundingFailed.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.refundClaim.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.autoCloseFunding.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.isDepositOpen.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.isSettlementOpen.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.currentVaultModeAndState.selector) return ROLE_PUBLIC;
        if (selector == FixedMaturityModule.fundingProgressBps.selector) return ROLE_PUBLIC;

        // Not registered - return special value
        return ROLE_UNREGISTERED;
    }

    /**
     * @notice Check if a selector is registered in this registry
     * @param selector The function selector to check
     * @return True if selector has a required role defined
     */
    function isRegistered(bytes4 selector) external pure returns (bool) {
        return getRequiredRole(selector) != ROLE_UNREGISTERED;
    }

    /**
     * @notice Check if a selector requires ROLE_OWNER
     * @param selector The function selector to check
     * @return True if selector must have ROLE_OWNER
     */
    function isOwnerSelector(bytes4 selector) external pure returns (bool) {
        return getRequiredRole(selector) == ROLE_OWNER;
    }

    /**
     * @notice Validate that a role assignment is correct for a selector
     * @param selector The function selector
     * @param role The role being assigned
     * @return True if assignment is valid
     * @dev Reverts with InvalidRoleForSelector if registered selector has wrong role
     */
    function validateRoleAssignment(bytes4 selector, uint8 role) public pure returns (bool) {
        uint8 required = getRequiredRole(selector);

        // Unregistered selectors can have any role
        if (required == ROLE_UNREGISTERED) {
            return true;
        }

        // Registered selectors must have exact role match
        if (role != required) {
            revert InvalidRoleForSelector(selector, role, required);
        }

        return true;
    }

    /**
     * @notice ALLOWLIST MODE: Require selector is registered (rejects unknown selectors)
     * @param selector The function selector to check
     * @dev Reverts with UnknownSelector if selector is not in the registry.
     *      Use this to enforce strict allowlist - blocks shadow selectors entirely.
     */
    function requireKnownSelector(bytes4 selector) external pure {
        if (getRequiredRole(selector) == ROLE_UNREGISTERED) {
            revert UnknownSelector(selector);
        }
    }

    /**
     * @notice ALLOWLIST MODE: Validate role AND require selector is known
     * @param selector The function selector
     * @param role The role being assigned
     * @return True if assignment is valid AND selector is registered
     * @dev Reverts with UnknownSelector if selector is not registered.
     *      Reverts with InvalidRoleForSelector if role doesn't match.
     *      This is the strictest validation mode - use for production.
     */
    function validateKnownSelectorRole(bytes4 selector, uint8 role) external pure returns (bool) {
        uint8 required = getRequiredRole(selector);

        // ALLOWLIST: Reject unknown selectors entirely
        if (required == ROLE_UNREGISTERED) {
            revert UnknownSelector(selector);
        }

        // Registered selectors must have exact role match
        if (role != required) {
            revert InvalidRoleForSelector(selector, role, required);
        }

        return true;
    }

    /**
     * @notice Batch validate multiple selector-role assignments
     * @param selectors Array of function selectors
     * @param roles Array of roles being assigned
     * @return True if all assignments are valid
     * @dev Reverts on first invalid assignment
     */
    function validateBatchRoleAssignment(bytes4[] calldata selectors, uint8[] calldata roles)
        external
        pure
        returns (bool)
    {
        uint256 len = selectors.length;
        require(len == roles.length, "length mismatch");

        for (uint256 i = 0; i < len;) {
            validateRoleAssignment(selectors[i], roles[i]);
            unchecked {
                ++i;
            }
        }

        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SELECTOR ENUMERATION (for validation/testing)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get all owner-critical selectors
     * @return selectors Array of all selectors that require ROLE_OWNER
     */
    function getOwnerSelectors() external pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](34);

        // Fee params
        selectors[0] = AdminModule.submitFeeParams.selector;
        selectors[1] = AdminModule.acceptFeeParams.selector;
        selectors[2] = AdminModule.revokeFeeParams.selector;

        // Perf params
        selectors[3] = AdminModule.submitPerfParams.selector;
        selectors[4] = AdminModule.acceptPerfParams.selector;
        selectors[5] = AdminModule.revokePerfParams.selector;

        // Min delay
        selectors[6] = AdminModule.submitMinDelay.selector;
        selectors[7] = AdminModule.acceptMinDelay.selector;
        selectors[8] = AdminModule.revokeMinDelay.selector;

        // Component setters
        selectors[9] = AdminModule.setParams.selector;
        selectors[10] = AdminModule.setBufferManager.selector;
        selectors[11] = AdminModule.setRouter.selector;
        selectors[12] = AdminModule.setHealthRegistry.selector;
        selectors[13] = AdminModule.setIncentives.selector;
        selectors[14] = AdminModule.setFeeCollector.selector;
        selectors[15] = AdminModule.setVetoer.selector;

        // Freeze/finalize
        selectors[16] = AdminModule.freezeParams.selector;
        selectors[17] = AdminModule.setEcosystem.selector;

        // Component timelock
        selectors[18] = AdminModule.enableComponentsTimelock.selector;
        selectors[19] = AdminModule.submitBufferManager.selector;
        selectors[20] = AdminModule.acceptBufferManager.selector;
        selectors[21] = AdminModule.revokeBufferManager.selector;
        selectors[22] = AdminModule.submitRouter.selector;
        selectors[23] = AdminModule.acceptRouter.selector;
        selectors[24] = AdminModule.revokeRouter.selector;

        // Dead deposit (inflation attack hardening)
        selectors[25] = AdminModule.seedDeadDeposit.selector;
        // Initial fees + perf params (one-shot setup)
        selectors[26] = AdminModule.setInitialFees.selector;
        selectors[27] = AdminModule.setInitialPerfParams.selector;
        selectors[28] = AdminModule.setIncentivesEngine.selector;
        selectors[29] = AdminModule.setRewardsPayoutManager.selector;
        // V10 Portfolio-Grade Allocation Engine
        selectors[30] = AdminModule.setRebalancePolicy.selector;
        selectors[31] = AdminModule.setRebalanceGuard.selector;
        selectors[32] = AdminModule.setExecutionMemory.selector;
        selectors[33] = AdminModule.setStrictExecutionMemory.selector;
    }

    /**
     * @notice Get count of owner-critical selectors
     * @return count Number of selectors requiring ROLE_OWNER
     */
    function ownerSelectorCount() external pure returns (uint256) {
        return 34;
    }

    /**
     * @notice Get count of all registered selectors
     * @return count Total number of registered selectors
     */
    // TODO: this could be a useless function, and it's already lagging as we have 7 LiquidityOps slectors but only 6 are here.
    // @dev If we keep this, we need to maintain it manually as selectors are added/removed -
    // consider if it's worth the maintenance burden.
    function totalRegisteredSelectors() external pure returns (uint256) {
        // 34 owner + 15 admin view + 6 queue write + 5 queue view + 11 ERC4626 + 6 LiquidityOps + 14 FM = 91
        return 91;
    }
}
