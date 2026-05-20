// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { CoreStorage } from "../../../src/core/storage/CoreStorage.sol";
import { FixedMaturityStorage, VaultMode, VaultState } from "../../../src/core/storage/FixedMaturityStorage.sol";
import { QueueStorage } from "../../../src/core/storage/QueueStorage.sol";
import { FixedMaturityModule } from "../../../src/core/modules/FixedMaturityModule.sol";
import { LiquidityOpsModule } from "../../../src/core/modules/LiquidityOpsModule.sol";

/// @title FixedMaturityHarness
/// @notice Test harness extending CoreHarness with FixedMaturityModule wired + unsafe FM state setters.
/// @dev NOT a test contract. Extend this for all FM test suites.
contract FixedMaturityHarness is CoreHarness {

    FixedMaturityModule public fmModule;
    LiquidityOpsModule public liqOpsModule;

    constructor(
        IERC20Metadata assetUSDC,
        string memory name_,
        string memory symbol_,
        address owner_,
        address treasury_,
        address params_
    )
        CoreHarness(assetUSDC, name_, symbol_, owner_, treasury_, params_)
    {
        // Deploy modules
        fmModule    = new FixedMaturityModule();
        liqOpsModule = new LiquidityOpsModule();

        // ── Wire FixedMaturityModule selectors ────────────────────────────────
        _setModuleUnsafe(FixedMaturityModule.setVaultModeFixedMaturity.selector,   address(fmModule), ROLE_OWNER);
        _setModuleUnsafe(FixedMaturityModule.configureFixedMaturity.selector,      address(fmModule), ROLE_OWNER);
        _setModuleUnsafe(FixedMaturityModule.startFixedMaturityCycle.selector,     address(fmModule), ROLE_OWNER);
        _setModuleUnsafe(FixedMaturityModule.activateFixedMaturityCycle.selector,  address(fmModule), ROLE_OWNER);
        _setModuleUnsafe(FixedMaturityModule.closeFixedMaturityCycle.selector,     address(fmModule), ROLE_OWNER);
        _setModuleUnsafe(FixedMaturityModule.recallFixedTermCapital.selector,      address(fmModule), ROLE_OWNER);
        _setModuleUnsafe(FixedMaturityModule.markMatured.selector,                 address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.markFundingFailed.selector,           address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.refundClaim.selector,                 address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.autoCloseFunding.selector,            address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.isDepositOpen.selector,               address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.isSettlementOpen.selector,            address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.currentVaultModeAndState.selector,    address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(FixedMaturityModule.fundingProgressBps.selector,          address(fmModule), ROLE_PUBLIC);
        // Additional view selectors from IFixedMaturityModule
        _setModuleUnsafe(bytes4(keccak256("isInstantExitOpen()")),                 address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("netFundedAssets()")),                   address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("isFundingSuccessful()")),               address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("isFundingTargetReached()")),            address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("finalPerformanceFeeStatus()")),         address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("fundingDeadlineTs()")),                 address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("maturityTs()")),                        address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("minFundingAssets()")),                  address(fmModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("fixedTermStrategy()")),                 address(fmModule), ROLE_PUBLIC);

        // ── Wire LiquidityOpsModule selectors ────────────────────────────────
        _setModuleUnsafe(LiquidityOpsModule.deployToStrategies.selector,           address(liqOpsModule), ROLE_OWNER);
        _setModuleUnsafe(LiquidityOpsModule.rebalanceStrategies.selector,          address(liqOpsModule), ROLE_OWNER);
        _setModuleUnsafe(LiquidityOpsModule.canDeploy.selector,                    address(liqOpsModule), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("deployToStrategiesWithPlan((address,uint256,bool)[],uint256)")),
                         address(liqOpsModule), ROLE_OWNER);
        _setModuleUnsafe(bytes4(keccak256("realizeForQueue(uint256)")),            address(liqOpsModule), ROLE_OWNER);
        _setModuleUnsafe(bytes4(keccak256("canRebalanceStrategies()")),            address(liqOpsModule), ROLE_PUBLIC);

        // Authorize fm module for internal processorMint/Burn calls
        CoreStorage.Layout storage cs = CoreStorage.layout();
        cs.isAuthorizedModule[address(fmModule)] = true;
    }

    // ── Unsafe FM state setters ───────────────────────────────────────────────

    function setFMStateUnsafe(VaultState state_) external {
        FixedMaturityStorage.layout().vaultState = state_;
    }

    function setFMModeUnsafe(VaultMode mode_) external {
        FixedMaturityStorage.layout().vaultMode = mode_;
    }

    /// @notice Set all FM config fields in one call, bypassing the one-shot guard.
    function setFMConfigUnsafe(
        uint64  maturityTs_,
        uint256 minFundingAssets_,
        uint256 targetFundingAssets_,
        uint64  fundingDeadlineTs_,
        bool    autoClose_,
        bool    instantExit_,
        uint256 forcePenaltyBps_,
        address strategy_
    ) external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        fm.maturityTs                    = maturityTs_;
        fm.minFundingAssets              = minFundingAssets_;
        fm.targetFundingAssets           = targetFundingAssets_;
        fm.fundingDeadlineTs             = fundingDeadlineTs_;
        fm.autoCloseFundingOnTarget      = autoClose_;
        fm.instantEnabledAfterMaturity   = instantExit_;
        fm.preMaturityForceExitPenaltyBps = forcePenaltyBps_;
        fm.fixedTermStrategy             = strategy_;
        fm.fixedTermConfigured           = true;
    }

    function setFundingFailedPPSUnsafe(uint256 pps_) external {
        FixedMaturityStorage.layout().fundingFailedPPS = pps_;
    }

    function setCommittedAssetsUnsafe(uint256 committed_, uint256 hotBuffer_) external {
        FixedMaturityStorage.Layout storage fm = FixedMaturityStorage.layout();
        fm.fixedTermCommittedAssets = committed_;
        fm.retainedHotBuffer        = hotBuffer_;
        fm.startingTs               = uint64(block.timestamp);
    }

    function setPendingSharesUnsafe(uint256 pendingShares_) external {
        QueueStorage.layout().pendingShares = pendingShares_;
    }

    // ── Storage getters (for test assertions) ────────────────────────────────

    function getFundingFailedPPS() external view returns (uint256) {
        return FixedMaturityStorage.layout().fundingFailedPPS;
    }

    function getRetainedHotBuffer() external view returns (uint256) {
        return FixedMaturityStorage.layout().retainedHotBuffer;
    }

    function getCommittedAssets() external view returns (uint256) {
        return FixedMaturityStorage.layout().fixedTermCommittedAssets;
    }

    function getFMVaultState() external view returns (VaultState) {
        return FixedMaturityStorage.layout().vaultState;
    }

    function getFMVaultMode() external view returns (VaultMode) {
        return FixedMaturityStorage.layout().vaultMode;
    }

    // ── CoreStorage unsafe helpers ────────────────────────────────────────────

    function setEpochStartUnsafe(uint64 ts) external {
        CoreStorage.layout().epochStart = ts;
    }
}
