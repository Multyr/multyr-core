// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { QueueModule } from "../modules/QueueModule.sol";
import { AdminModule } from "../modules/AdminModule.sol";
import { LiquidityOpsModule } from "../modules/LiquidityOpsModule.sol";
import { FixedMaturityModule } from "../modules/FixedMaturityModule.sol";
import { CoreVault } from "../CoreVault.sol";

/// @title SelectorLib
/// @notice Source of truth for all Diamond-lite module selectors and their required roles
/// @dev This library ensures complete coverage and prevents "foot-gun" misconfigurations
library SelectorLib {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ROLE CONSTANTS (must match CoreVault)
    // ═══════════════════════════════════════════════════════════════════════════════
    uint8 internal constant ROLE_PUBLIC = 0;
    uint8 internal constant ROLE_OWNER = 1;
    uint8 internal constant ROLE_GUARDIAN = 2;
    uint8 internal constant ROLE_MODULE = 3;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SELECTOR COUNTS (for validation)
    // ═══════════════════════════════════════════════════════════════════════════════
    uint256 internal constant QUEUE_MODULE_SELECTORS = 6; // +1: compactQueue
    uint256 internal constant QUEUE_MODULE_VIEW_SELECTORS = 5; // +1: requiredHotForBatch, +1: settlePreview
    uint256 internal constant ADMIN_MODULE_OWNER_SELECTORS = 34; // +4: V10 rebalance policy selectors
    uint256 internal constant ADMIN_MODULE_VIEW_SELECTORS = 15; // +1: getForceExitPenalty, +1: isPerfInitialized
    uint256 internal constant ERC4626_MODULE_SELECTORS = 11; // +1: forceWithdraw, +1: forceWithdrawAll
    uint256 internal constant LIQUIDITY_OPS_MODULE_SELECTORS = 7; // canDeploy, deployToStrategies, deployToStrategiesWithPlan, realizeForQueue, realizeForReserveAndOps, canRebalanceStrategies, rebalanceStrategies
    uint256 internal constant FIXED_MATURITY_MODULE_SELECTORS = 14; // 13 plan selectors + autoCloseFunding

    uint256 internal constant TOTAL_SELECTORS = QUEUE_MODULE_SELECTORS + QUEUE_MODULE_VIEW_SELECTORS
        + ADMIN_MODULE_OWNER_SELECTORS + ADMIN_MODULE_VIEW_SELECTORS + ERC4626_MODULE_SELECTORS
        + LIQUIDITY_OPS_MODULE_SELECTORS + FIXED_MATURITY_MODULE_SELECTORS;

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUEUE MODULE SELECTORS (PUBLIC)
    // ═══════════════════════════════════════════════════════════════════════════════
    function getQueueModuleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](QUEUE_MODULE_SELECTORS);
        selectors[0] = QueueModule.requestClaim.selector;
        selectors[1] = QueueModule.cancelClaim.selector;
        selectors[2] = QueueModule.processQueuedRedemptions.selector;
        selectors[3] = QueueModule.settleFeesAndProcessQueue.selector;
        selectors[4] = QueueModule.endEpochCrystallize.selector;
        selectors[5] = QueueModule.compactQueue.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUEUE MODULE VIEW SELECTORS (PUBLIC)
    // ═══════════════════════════════════════════════════════════════════════════════
    function getQueueModuleViewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](QUEUE_MODULE_VIEW_SELECTORS);
        selectors[0] = QueueModule.nextClaimId.selector;
        selectors[1] = QueueModule.queueLength.selector;
        selectors[2] = QueueModule.pendingShares.selector;
        selectors[3] = QueueModule.requiredHotForBatch.selector;
        selectors[4] = QueueModule.settlePreview.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN MODULE SELECTORS (OWNER ONLY)
    // ═══════════════════════════════════════════════════════════════════════════════
    function getAdminModuleOwnerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](ADMIN_MODULE_OWNER_SELECTORS);
        selectors[0] = AdminModule.submitFeeParams.selector;
        selectors[1] = AdminModule.acceptFeeParams.selector;
        selectors[2] = AdminModule.revokeFeeParams.selector;
        selectors[3] = AdminModule.submitPerfParams.selector;
        selectors[4] = AdminModule.acceptPerfParams.selector;
        selectors[5] = AdminModule.revokePerfParams.selector;
        selectors[6] = AdminModule.submitMinDelay.selector;
        selectors[7] = AdminModule.acceptMinDelay.selector;
        selectors[8] = AdminModule.revokeMinDelay.selector;
        selectors[9] = AdminModule.setParams.selector;
        selectors[10] = AdminModule.setBufferManager.selector;
        selectors[11] = AdminModule.setRouter.selector;
        selectors[12] = AdminModule.setHealthRegistry.selector;
        selectors[13] = AdminModule.setIncentives.selector;
        selectors[14] = AdminModule.setFeeCollector.selector;
        selectors[15] = AdminModule.setVetoer.selector;
        selectors[16] = AdminModule.freezeParams.selector;
        selectors[17] = AdminModule.setEcosystem.selector;
        // Component timelock functions
        selectors[18] = AdminModule.enableComponentsTimelock.selector;
        selectors[19] = AdminModule.submitBufferManager.selector;
        selectors[20] = AdminModule.acceptBufferManager.selector;
        selectors[21] = AdminModule.revokeBufferManager.selector;
        selectors[22] = AdminModule.submitRouter.selector;
        selectors[23] = AdminModule.acceptRouter.selector;
        selectors[24] = AdminModule.revokeRouter.selector;
        // Dead deposit (inflation attack hardening)
        selectors[25] = AdminModule.seedDeadDeposit.selector;
        // Initial fees (one-shot setup)
        selectors[26] = AdminModule.setInitialFees.selector;
        // Initial perf params (one-shot setup)
        selectors[27] = AdminModule.setInitialPerfParams.selector;
        // IncentivesEngine v2 + RewardsPayoutManager
        selectors[28] = AdminModule.setIncentivesEngine.selector;
        selectors[29] = AdminModule.setRewardsPayoutManager.selector;
        // V10 Portfolio-Grade Allocation Engine
        selectors[30] = AdminModule.setRebalancePolicy.selector;
        selectors[31] = AdminModule.setRebalanceGuard.selector;
        selectors[32] = AdminModule.setExecutionMemory.selector;
        selectors[33] = AdminModule.setStrictExecutionMemory.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN MODULE SELECTORS (VIEW - PUBLIC)
    // ═══════════════════════════════════════════════════════════════════════════════
    function getAdminModuleViewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](ADMIN_MODULE_VIEW_SELECTORS);
        selectors[0] = AdminModule.getPendingFeeParams.selector;
        selectors[1] = AdminModule.getPendingPerfParams.selector;
        selectors[2] = AdminModule.getPendingMinDelay.selector;
        selectors[3] = AdminModule.getFeeParams.selector;
        selectors[4] = AdminModule.getPerfParams.selector;
        selectors[5] = AdminModule.getMinDelay.selector;
        selectors[6] = AdminModule.getEcosystem.selector;
        selectors[7] = AdminModule.isComponentsTimelocked.selector;
        selectors[8] = AdminModule.getPendingBufferManager.selector;
        selectors[9] = AdminModule.getPendingRouter.selector;
        selectors[10] = AdminModule.isDeadDepositDone.selector;
        selectors[11] = AdminModule.getImmediateExitPenalty.selector;
        selectors[12] = AdminModule.isFeesInitialized.selector;
        selectors[13] = AdminModule.getForceExitPenalty.selector;
        selectors[14] = AdminModule.isPerfInitialized.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERC4626 MODULE SELECTORS (PUBLIC)
    // deposit, depositFor, mint, withdraw, redeem + 4 slippage overloads = 9 selectors
    // Using explicit keccak256 for all because of overloaded function selectors
    // ═══════════════════════════════════════════════════════════════════════════════
    function getERC4626ModuleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](ERC4626_MODULE_SELECTORS);
        // Standard ERC4626 functions (explicit keccak256 due to overloads)
        selectors[0] = bytes4(keccak256("deposit(uint256,address)")); // 0x6e553f65
        selectors[1] = bytes4(keccak256("depositFor(uint256,address,address)")); // depositFor
        selectors[2] = bytes4(keccak256("mint(uint256,address)")); // 0x94bf804d
        selectors[3] = bytes4(keccak256("withdraw(uint256,address,address)")); // 0xb460af94
        selectors[4] = bytes4(keccak256("redeem(uint256,address,address)")); // 0xba087652
        // Slippage-protected overloads
        selectors[5] = bytes4(keccak256("deposit(uint256,address,uint256)"));
        selectors[6] = bytes4(keccak256("mint(uint256,address,uint256)"));
        selectors[7] = bytes4(keccak256("withdraw(uint256,address,address,uint256)"));
        selectors[8] = bytes4(keccak256("redeem(uint256,address,address,uint256)"));
        // Force withdraw (guaranteed exit — legacy, with plan)
        selectors[9] =
            bytes4(keccak256("forceWithdraw(uint256,address,address,(address,uint256)[],uint256)"));
        // Force withdraw all (guaranteed exit — W2 policy, no plan, no LossCap)
        selectors[10] = bytes4(keccak256("forceWithdrawAll(address)"));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // LIQUIDITY OPS MODULE SELECTORS (PUBLIC - keeper/permissionless)
    // ═══════════════════════════════════════════════════════════════════════════════
    function getLiquidityOpsModuleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](LIQUIDITY_OPS_MODULE_SELECTORS);
        selectors[0] = LiquidityOpsModule.canDeploy.selector;
        selectors[1] = LiquidityOpsModule.deployToStrategies.selector;
        selectors[2] = LiquidityOpsModule.deployToStrategiesWithPlan.selector;
        selectors[3] = LiquidityOpsModule.realizeForQueue.selector;
        selectors[4] = LiquidityOpsModule.realizeForReserveAndOps.selector;
        selectors[5] = LiquidityOpsModule.canRebalanceStrategies.selector;
        selectors[6] = LiquidityOpsModule.rebalanceStrategies.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FIXED MATURITY MODULE SELECTORS
    // ═══════════════════════════════════════════════════════════════════════════════
    function getFixedMaturityModuleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](FIXED_MATURITY_MODULE_SELECTORS);
        // Governance (ROLE_OWNER)
        selectors[0]  = FixedMaturityModule.setVaultModeFixedMaturity.selector;
        selectors[1]  = FixedMaturityModule.configureFixedMaturity.selector;
        selectors[2]  = FixedMaturityModule.startFixedMaturityCycle.selector;
        selectors[3]  = FixedMaturityModule.activateFixedMaturityCycle.selector;
        selectors[4]  = FixedMaturityModule.closeFixedMaturityCycle.selector;
        selectors[5]  = FixedMaturityModule.recallFixedTermCapital.selector;
        // Permissionless time/condition-gated (ROLE_PUBLIC)
        selectors[6]  = FixedMaturityModule.markMatured.selector;
        selectors[7]  = FixedMaturityModule.markFundingFailed.selector;
        selectors[8]  = FixedMaturityModule.refundClaim.selector;
        selectors[9]  = FixedMaturityModule.autoCloseFunding.selector;
        // Views (ROLE_PUBLIC)
        selectors[10] = FixedMaturityModule.isDepositOpen.selector;
        selectors[11] = FixedMaturityModule.isSettlementOpen.selector;
        selectors[12] = FixedMaturityModule.currentVaultModeAndState.selector;
        selectors[13] = FixedMaturityModule.fundingProgressBps.selector;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VALIDATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Check if all required selectors are mapped in a router (legacy 3-arg version)
    /// @dev Backward compatible - does NOT check ERC4626Module selectors
    function validateAllSelectorsMapped(
        CoreVault routerAddr,
        address queueModule,
        address adminModule
    ) internal view returns (bool valid, uint256 missingCount) {
        return validateAllSelectorsMappedWithERC4626(
            routerAddr, queueModule, adminModule, address(0)
        );
    }

    /// @notice Check if all required selectors are mapped in a router (includes ERC4626Module)
    /// @param routerAddr The CoreVault to validate
    /// @param queueModule Expected QueueModule address
    /// @param adminModule Expected AdminModule address
    /// @param erc4626Module Expected ERC4626Module address (can be address(0) to skip ERC4626 validation)
    /// @return valid True if all selectors are correctly mapped
    /// @return missingCount Number of unmapped selectors
    function validateAllSelectorsMappedWithERC4626(
        CoreVault routerAddr,
        address queueModule,
        address adminModule,
        address erc4626Module
    ) internal view returns (bool valid, uint256 missingCount) {
        missingCount = 0;

        // Check QueueModule selectors
        bytes4[] memory queueSels = getQueueModuleSelectors();
        for (uint256 i = 0; i < queueSels.length; i++) {
            if (routerAddr.moduleOf(queueSels[i]) != queueModule) {
                missingCount++;
            }
            if (routerAddr.roleOf(queueSels[i]) != ROLE_PUBLIC) {
                missingCount++;
            }
        }

        // Check QueueModule view selectors
        bytes4[] memory queueViewSels = getQueueModuleViewSelectors();
        for (uint256 i = 0; i < queueViewSels.length; i++) {
            if (routerAddr.moduleOf(queueViewSels[i]) != queueModule) {
                missingCount++;
            }
            if (routerAddr.roleOf(queueViewSels[i]) != ROLE_PUBLIC) {
                missingCount++;
            }
        }

        // Check AdminModule owner selectors
        bytes4[] memory adminOwnerSels = getAdminModuleOwnerSelectors();
        for (uint256 i = 0; i < adminOwnerSels.length; i++) {
            if (routerAddr.moduleOf(adminOwnerSels[i]) != adminModule) {
                missingCount++;
            }
            if (routerAddr.roleOf(adminOwnerSels[i]) != ROLE_OWNER) {
                missingCount++;
            }
        }

        // Check AdminModule view selectors
        bytes4[] memory adminViewSels = getAdminModuleViewSelectors();
        for (uint256 i = 0; i < adminViewSels.length; i++) {
            if (routerAddr.moduleOf(adminViewSels[i]) != adminModule) {
                missingCount++;
            }
            if (routerAddr.roleOf(adminViewSels[i]) != ROLE_PUBLIC) {
                missingCount++;
            }
        }

        // Check ERC4626Module selectors (if provided)
        if (erc4626Module != address(0)) {
            bytes4[] memory erc4626Sels = getERC4626ModuleSelectors();
            for (uint256 i = 0; i < erc4626Sels.length; i++) {
                if (routerAddr.moduleOf(erc4626Sels[i]) != erc4626Module) {
                    missingCount++;
                }
                if (routerAddr.roleOf(erc4626Sels[i]) != ROLE_PUBLIC) {
                    missingCount++;
                }
            }
        }

        // Note: processorMint/processorBurn/processorTransfer/processorSpendAllowance
        // are NOT routed via modules - they use isAuthorizedModule pattern
        // Note: LiquidityOpsModule selectors are NOT checked here for backward compat.
        // Use validateAllSelectorsMappedFull() for complete validation.

        valid = missingCount == 0;
    }

    /// @notice Full validation including all modules (ERC4626 + LiquidityOps)
    /// @param routerAddr The CoreVault to validate
    /// @param queueModule Expected QueueModule address
    /// @param adminModule Expected AdminModule address
    /// @param erc4626Module Expected ERC4626Module address
    /// @param liquidityOpsModule Expected LiquidityOpsModule address
    /// @return valid True if all selectors are correctly mapped
    /// @return missingCount Number of unmapped selectors
    function validateAllSelectorsMappedFull(
        CoreVault routerAddr,
        address queueModule,
        address adminModule,
        address erc4626Module,
        address liquidityOpsModule
    ) internal view returns (bool valid, uint256 missingCount) {
        (valid, missingCount) = validateAllSelectorsMappedWithERC4626(
                routerAddr, queueModule, adminModule, erc4626Module
            );

        // Check LiquidityOpsModule selectors (if provided)
        if (liquidityOpsModule != address(0)) {
            bytes4[] memory liquidityOpsSels = getLiquidityOpsModuleSelectors();
            for (uint256 i = 0; i < liquidityOpsSels.length; i++) {
                if (routerAddr.moduleOf(liquidityOpsSels[i]) != liquidityOpsModule) {
                    missingCount++;
                }
                if (routerAddr.roleOf(liquidityOpsSels[i]) != ROLE_PUBLIC) {
                    missingCount++;
                }
            }
        }

        valid = missingCount == 0;
    }

    /// @notice Get expected role for a selector
    /// @param selector The function selector
    /// @return role Expected role (0=PUBLIC, 1=OWNER, 2=GUARDIAN, 3=MODULE)
    /// @return found True if selector is in the registry
    function getExpectedRole(bytes4 selector) internal pure returns (uint8 role, bool found) {
        // QueueModule (PUBLIC)
        bytes4[] memory queueSels = getQueueModuleSelectors();
        for (uint256 i = 0; i < queueSels.length; i++) {
            if (queueSels[i] == selector) return (ROLE_PUBLIC, true);
        }

        // QueueModule view (PUBLIC)
        bytes4[] memory queueViewSels = getQueueModuleViewSelectors();
        for (uint256 i = 0; i < queueViewSels.length; i++) {
            if (queueViewSels[i] == selector) return (ROLE_PUBLIC, true);
        }

        // AdminModule owner functions
        bytes4[] memory adminOwnerSels = getAdminModuleOwnerSelectors();
        for (uint256 i = 0; i < adminOwnerSels.length; i++) {
            if (adminOwnerSels[i] == selector) return (ROLE_OWNER, true);
        }

        // AdminModule view functions
        bytes4[] memory adminViewSels = getAdminModuleViewSelectors();
        for (uint256 i = 0; i < adminViewSels.length; i++) {
            if (adminViewSels[i] == selector) return (ROLE_PUBLIC, true);
        }

        // ERC4626Module (PUBLIC)
        bytes4[] memory erc4626Sels = getERC4626ModuleSelectors();
        for (uint256 i = 0; i < erc4626Sels.length; i++) {
            if (erc4626Sels[i] == selector) return (ROLE_PUBLIC, true);
        }

        // LiquidityOpsModule (PUBLIC)
        bytes4[] memory liquidityOpsSels = getLiquidityOpsModuleSelectors();
        for (uint256 i = 0; i < liquidityOpsSels.length; i++) {
            if (liquidityOpsSels[i] == selector) return (ROLE_PUBLIC, true);
        }

        return (0, false);
    }
}
