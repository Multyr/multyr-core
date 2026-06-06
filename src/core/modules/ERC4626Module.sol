// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CoreStorage } from "../storage/CoreStorage.sol";
import { FeeStorage } from "../storage/FeeStorage.sol";
import { Events } from "../libraries/Events.sol";
import { Percentage } from "../../libs/Percentage.sol";
import { RevertClassifier } from "../libraries/RevertClassifier.sol";
import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../interfaces/IStrategyRouter.sol";
import { IIncentives } from "../../interfaces/IIncentives.sol";
import { IIncentivesEngine } from "../../interfaces/IIncentivesEngine.sol";
import { ICoreVault } from "../../interfaces/ICoreVault.sol";
import { ExitEngineLib } from "../libraries/ExitEngineLib.sol";
import {
    FixedMaturityStorage, VaultMode, VaultState,
    _checkDepositsAllowed, _checkForceExitAllowed
} from "../storage/FixedMaturityStorage.sol";
import { FixedMaturityLogicLib } from "../libraries/FixedMaturityLogicLib.sol";

/// @title ERC4626Module v3 (ExitEngineLib Architecture)
/// @notice Handles ERC4626 user-facing operations via delegatecall from CoreVault.
/// @dev v9 changes (ExitEngineLib refactor):
///      - withdraw()/redeem() ALWAYS revert AsyncWithdrawalRequired
///      - Users must use QueueModule.requestClaim() for all exits
///      - forceWithdraw/forceWithdrawAll remain instant (fee via ExitEngineLib)
///      - deposit/mint unchanged (O(1), no routing)
///
/// EXIT SEMANTICS:
///   withdraw/redeem: REVERT AsyncWithdrawalRequired (ERC4626 compliant: maxWithdraw=0)
///   forceWithdraw: FORCE mode, no cap consumption, penalty via ExitEngineLib
///   forceWithdrawAll: FORCE mode, best-effort, fee via transfer
///
/// INVARIANTS:
///   1. withdraw/redeem CANNOT ever transfer assets
///   2. totalSupply NEVER increases on exit
///   3. forceWithdraw does NOT consume epoch cap
contract ERC4626Module {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error Paused();
    error DepositsPaused();
    error WithdrawalsPaused();
    error ZeroAmount();
    error ZeroAddress();
    error DepositBelowMinimum(uint256 assets, uint256 minimum);
    error VaultDepositCapExceeded(uint256 totalAssetsAfter, uint256 cap);
    error UserDepositCapExceeded(uint256 userAssetsAfter, uint256 cap);
    error SlippageExceeded();
    error ReentrancyGuardLocked();
    error NavStale();
    error NavInvalid();
    error InsufficientLiquidity();
    error SharesLocked();
    error WithdrawalLimitExceeded();
    // Force withdraw errors
    error EmptyPlan();
    error PlanTooLong();
    error InvalidPlanAmount();
    error PlanSumInsufficient();
    error StrategyDisabled(address strat);

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════
    uint256 public constant MAX_WARM_NAV_AGE = 15 minutes;
    uint256 public constant MAX_FORCE_LEGS = 10;

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEPOSIT FUNCTIONS - Standard (O(1) - NO router calls)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Deposit assets and receive shares
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        return _depositInternal(assets, receiver, msg.sender);
    }

    /// @notice Deposit assets on behalf of another user (router model)
    /// @dev msg.sender is always the payer. Routers (e.g. DepositRouter) pull
    ///      user tokens to themselves first, then call depositFor(amount, user)
    ///      so the router is both msg.sender and the token source. This eliminates
    ///      the unauthorized-payer attack where any caller could drain any address
    ///      with a standing vault approval.
    function depositFor(uint256 assets, address receiver)
        external
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        return _depositInternal(assets, receiver, msg.sender);
    }

    /// @notice Mint exact shares by depositing assets
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        return _mintInternal(shares, receiver, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // DEPOSIT FUNCTIONS - Slippage Protected
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Deposit with minimum shares protection
    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        returns (uint256 shares)
    {
        _notPausedDeposits();

        FeeStorage.Layout storage f = FeeStorage.layout();
        uint256 feeA = Percentage.mulBpsDown(assets, f.fee.depBps);
        uint256 expected = _previewDeposit(assets - feeA);
        if (expected < minShares) revert SlippageExceeded();

        return _depositInternal(assets, receiver, msg.sender);
    }

    /// @notice Mint with maximum assets protection
    function mint(uint256 shares, address receiver, uint256 maxAssets)
        external
        returns (uint256 assets)
    {
        _notPausedDeposits();

        if (shares == 0) revert ZeroAmount();
        uint256 expected = _previewMint(shares);
        if (expected > maxAssets) revert SlippageExceeded();

        return _mintInternal(shares, receiver, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL FUNCTIONS — ALWAYS REVERT (queued protocol)
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERC4626 compliance: maxWithdraw/maxRedeem return 0, so these MUST revert.
    // Users MUST use QueueModule.requestClaim() for all exits.

    /// @notice DISABLED — use requestClaim() instead
    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert ExitEngineLib.AsyncWithdrawalRequired();
    }

    /// @notice DISABLED — use requestClaim() instead
    function redeem(uint256, address, address) external pure returns (uint256) {
        revert ExitEngineLib.AsyncWithdrawalRequired();
    }

    /// @notice DISABLED — use requestClaim() instead
    function withdraw(uint256, address, address, uint256) external pure returns (uint256) {
        revert ExitEngineLib.AsyncWithdrawalRequired();
    }

    /// @notice DISABLED — use requestClaim() instead
    function redeem(uint256, address, address, uint256) external pure returns (uint256) {
        revert ExitEngineLib.AsyncWithdrawalRequired();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FORCE WITHDRAW (Guaranteed Exit)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Force withdraw with user-provided plan - guaranteed exit (bypasses lock period)
    /// @dev BYPASSES: lock period, queue, epoch cap
    /// @dev MAINTAINS: paused check, loss caps, slippage, plan validation
    function forceWithdraw(
        uint256 assets,
        address receiver,
        address owner_,
        IStrategyRouter.Pull[] calldata plan,
        uint256 maxShares
    ) external returns (uint256 sharesSpent) {
        // FixedMaturity gate: forceWithdraw only allowed in Active state (or OpenEnded).
        // Blocked in: Funding, Starting, Matured, Closed, FundingFailed.
        _checkForceExitAllowed(FixedMaturityStorage.layout());

        _notPausedWithdrawals();
        _enterNonReentrant();

        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        // NAV freshness before convertToAssets (W2: never block)
        _trySoftRefreshWarmNav();

        // Calculate base shares
        uint256 baseShares = _previewWithdraw(assets);

        // Fee via ExitEngineLib (FORCE mode)
        (uint256 totalFeeShares, uint256 userSharesFromFee) =
            ExitEngineLib.computeFeeShares(baseShares, ExitEngineLib.ExitMode.FORCE, f.fee);

        // We need baseShares for assets + totalFeeShares for fees
        sharesSpent = baseShares + totalFeeShares;

        // Slippage check
        if (sharesSpent > maxShares) revert SlippageExceeded();

        // Allowance if caller != owner
        if (msg.sender != owner_) {
            _processorSpendAllowance(owner_, msg.sender, sharesSpent);
        }

        // Gross = assets + fee equivalent
        uint256 feeAssetsEq = totalFeeShares == 0 ? 0 : _convertToAssets(totalFeeShares);
        uint256 gross = assets + feeAssetsEq;

        // Anti-abuse limits (bypasses lock period)
        _checkWithdrawalLimitsForForce(owner_, gross, core);

        // Source liquidity with user plan
        _sourceLiquidityForForceWithdraw(assets, plan, core);

        // Transfer fee shares to feeCollector (NO mint — anti-dilution)
        if (totalFeeShares > 0) {
            _processorTransfer(owner_, core.feeCollector, totalFeeShares);
            emit Events.FeePaid(owner_, core.feeCollector, totalFeeShares);

            // Emit detailed fee events
            uint16 witBps = f.fee.witBps;
            uint16 forceBps = f.fee.forceExitPenaltyBps;
            if (witBps > 0) {
                uint256 witFeeShares = Percentage.mulBpsUp(baseShares, witBps);
                uint256 witFeeAssets = _convertToAssets(witFeeShares);
                emit Events.WithdrawFeeTaken(owner_, witFeeAssets, witFeeShares);
            }
            if (forceBps > 0) {
                uint256 forcePenaltyShares = Percentage.mulBpsUp(baseShares, forceBps);
                emit Events.ForceExitPenaltyApplied(owner_, forcePenaltyShares);
            }
        }

        // Sync incentives BEFORE burn (assets-based, try/catch)
        _notifyIncentivesExit(owner_, assets, core);

        // Burn base shares from owner
        _processorBurn(owner_, baseShares);

        // Transfer exact assets to receiver
        IERC20(_asset()).safeTransfer(receiver, assets);

        emit Events.ForceWithdrawExecuted(msg.sender, owner_, receiver, assets, sharesSpent);
        emit Events.ForceExit(owner_, sharesSpent, assets, totalFeeShares);

        _exitNonReentrant();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FORCE WITHDRAW ALL — Deterministic Exit (W2 Policy)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Guaranteed exit: burns ALL caller shares, pulls liquidity from all sources
    function forceWithdrawAll(address receiver) external returns (uint256 assetsReceived) {
        // FixedMaturity gate: same as forceWithdraw — only Active state or OpenEnded.
        _checkForceExitAllowed(FixedMaturityStorage.layout());

        _notPausedWithdrawals();
        _enterNonReentrant();

        if (receiver == address(0)) revert ZeroAddress();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        // NAV freshness before convertToAssets (W2: never block)
        _trySoftRefreshWarmNav();

        // Read all shares
        uint256 shares = _balanceOf(msg.sender);
        if (shares == 0) revert ZeroAmount();

        // Fee via ExitEngineLib (FORCE mode)
        (uint256 totalFeeShares, uint256 netShares) =
            ExitEngineLib.computeFeeShares(shares, ExitEngineLib.ExitMode.FORCE, f.fee);

        // Target assets from net shares
        uint256 targetAssets = _convertToAssets(netShares);

        // Anti-abuse limits (bypasses lock period)
        _checkWithdrawalLimitsForForce(msg.sender, targetAssets, core);

        // Transfer fee shares to FeeCollector (SHARES, not USDC)
        if (totalFeeShares > 0) {
            _processorTransfer(msg.sender, core.feeCollector, totalFeeShares);
            emit Events.FeePaid(msg.sender, core.feeCollector, totalFeeShares);

            uint16 witBps = f.fee.witBps;
            uint16 forceBps = f.fee.forceExitPenaltyBps;
            if (witBps > 0) {
                uint256 witFeeShares = Percentage.mulBpsUp(shares, witBps);
                emit Events.WithdrawFeeTaken(
                    msg.sender, _convertToAssets(witFeeShares), witFeeShares
                );
            }
            if (forceBps > 0) {
                uint256 forcePenaltyShares = Percentage.mulBpsUp(shares, forceBps);
                emit Events.ForceExitPenaltyTaken(
                    msg.sender, _convertToAssets(forcePenaltyShares), forcePenaltyShares
                );
            }
        }

        // Sync incentives BEFORE burn (assets-based, try/catch)
        _notifyIncentivesExit(msg.sender, targetAssets, core);

        // Pull liquidity — deterministic, no plan, no LossCap
        _forcePullAllLiquidity(targetAssets, core);

        // Burn net shares
        _processorBurn(msg.sender, netShares);

        // Payout = min(pulled, targetAssets) — best-effort
        address assetAddr = _asset();
        uint256 hot = IERC20(assetAddr).balanceOf(address(this));
        assetsReceived = hot >= targetAssets ? targetAssets : hot;

        if (assetsReceived > 0) {
            IERC20(assetAddr).safeTransfer(receiver, assetsReceived);
        }

        // NO consumeEpochCap — force bypasses cap
        emit ForceWithdrawAllExecuted(
            msg.sender, receiver, shares, assetsReceived, targetAssets
        );
        emit Events.ForceExit(msg.sender, shares, assetsReceived, totalFeeShares);

        _exitNonReentrant();
    }

    event ForceWithdrawAllExecuted(
        address indexed caller,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 assetsReceived,
        uint256 targetAssets
    );

    /// @dev Deterministic liquidity pull: hot → warm → strategy
    function _forcePullAllLiquidity(
        uint256 target,
        CoreStorage.Layout storage core
    ) internal {
        address assetAddr = _asset();
        uint256 hot = IERC20(assetAddr).balanceOf(address(this));
        if (hot >= target) return;

        uint256 needed = target - hot;

        IBufferManager bm = core.bufferManager;
        if (address(bm) != address(0)) {
            (, uint256 pulled) = bm.forceRefill(needed);
            if (pulled > 0) {
                hot = IERC20(assetAddr).balanceOf(address(this));
                if (hot >= target) return;
                needed = target - hot;
            }
        }

        IStrategyRouter r = core.router;
        if (address(r) != address(0) && needed > 0) {
            r.forceRedeemForWithdraw(needed);
        }
    }

    /// @dev Withdrawal limits for forceWithdraw — BYPASSES lock period
    function _checkWithdrawalLimitsForForce(
        address owner_,
        uint256 gross,
        CoreStorage.Layout storage core
    ) internal {
        if (address(core.params) == address(0)) return;

        IParamsProvider.WithdrawalParams memory wp =
            core.params.getWithdrawalParams(address(this));

        // Per-transaction limit (anti-abuse)
        if (wp.maxWithdrawalPerTx > 0 && gross > wp.maxWithdrawalPerTx) {
            revert WithdrawalLimitExceeded();
        }

        // Per-block limit (anti-abuse)
        if (wp.maxWithdrawalPerBlock > 0) {
            uint256 blockWithdrawn = core.blockWithdrawals[block.number];
            if (blockWithdrawn + gross > wp.maxWithdrawalPerBlock) {
                revert WithdrawalLimitExceeded();
            }
            core.blockWithdrawals[block.number] = blockWithdrawn + gross;
        }
    }

    /// @dev Source liquidity with user plan for force withdraw
    function _sourceLiquidityForForceWithdraw(
        uint256 assets,
        IStrategyRouter.Pull[] calldata plan,
        CoreStorage.Layout storage core
    ) internal {
        address assetAddr = _asset();
        uint256 hot = IERC20(assetAddr).balanceOf(address(this));

        if (hot >= assets) return;

        uint256 needed = assets - hot;

        IBufferManager bm = core.bufferManager;
        if (address(bm) != address(0)) {
            try bm.refill(needed) {
                hot = IERC20(assetAddr).balanceOf(address(this));
                if (hot >= assets) return;
                needed = assets - hot;
            } catch {}
        }

        _validateAndExecutePlan(plan, needed, core);

        hot = IERC20(assetAddr).balanceOf(address(this));
        if (hot < assets) {
            revert InsufficientLiquidity();
        }
    }

    /// @dev Validate plan constraints and execute via router
    function _validateAndExecutePlan(
        IStrategyRouter.Pull[] calldata plan,
        uint256 needed,
        CoreStorage.Layout storage core
    ) internal {
        if (plan.length == 0) revert EmptyPlan();
        if (plan.length > MAX_FORCE_LEGS) revert PlanTooLong();

        IStrategyRouter r = core.router;
        if (address(r) == address(0)) revert InsufficientLiquidity();

        uint256 planSum = 0;
        for (uint256 i = 0; i < plan.length; i++) {
            if (plan[i].amount == 0) revert InvalidPlanAmount();
            if (!r.isStrategyEnabled(plan[i].strat)) revert StrategyDisabled(plan[i].strat);
            planSum += plan[i].amount;
        }
        if (planSum < needed) revert PlanSumInsufficient();

        try r.executeRedeemBatch(plan) {}
        catch (bytes memory reason) {
            if (RevertClassifier.isCritical(reason)) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: DEPOSIT LOGIC
    // ═══════════════════════════════════════════════════════════════════════════════

    function _depositInternal(uint256 assets, address receiver, address payer)
        internal
        returns (uint256 shares)
    {
        // FixedMaturity gate: blocks deposits in Starting/Active/Matured/Closed/FundingFailed.
        // OpenEnded vaults: zero overhead (early return in _checkDepositsAllowed).
        _checkDepositsAllowed(FixedMaturityStorage.layout());

        _notPausedDeposits();
        _enterNonReentrant();

        if (assets == 0) revert ZeroAmount();
        _ensureFreshWarmNav();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();
        _enforceDepositLimits(core, receiver, assets, assets);

        uint256 feeA = Percentage.mulBpsDown(assets, f.fee.depBps);
        uint256 net = assets - feeA;
        shares = _previewDeposit(net);

        uint256 sharesFee = feeA > 0 ? _previewDeposit(feeA) : 0;

        IERC20(_asset()).safeTransferFrom(payer, address(this), assets);

        // Mint GROSS shares to receiver, then TRANSFER fee to feeCollector.
        // This is NON-DILUTIVE: totalSupply increases by convertToShares(assets),
        // which is proportional to totalAssets increase. PPS stays unchanged.
        // (Previously: separate mint to feeCollector was DILUTIVE.)
        _processorMint(receiver, shares + sharesFee);
        core.lastDepositTs[receiver] = uint64(block.timestamp);

        if (sharesFee > 0) {
            _processorTransfer(receiver, core.feeCollector, sharesFee);
        }
        emit Events.DepositFeeTaken(payer, feeA, sharesFee);
        emit IERC4626.Deposit(payer, receiver, assets, shares);

        if (payer != msg.sender) {
            emit Events.DepositForExecuted(payer, receiver, assets, shares);
        }

        _notifyIncentivesDeposit(receiver, net, core);

        // FixedMaturity auto-close: if target reached in Funding with autoClose enabled,
        // transition Funding → Starting. OpenEnded: all conditions false, zero-cost.
        {
            FixedMaturityStorage.Layout storage _fm = FixedMaturityStorage.layout();
            if (
                _fm.vaultMode == VaultMode.FixedMaturity
                    && _fm.vaultState == VaultState.Funding
                    && _fm.fixedTermConfigured
                    && _fm.autoCloseFundingOnTarget
                    && _fm.startingTs == 0
                    && FixedMaturityLogicLib.isFundingTargetReached(_fm, net)
            ) {
                _triggerAutoClose();
            }
        }

        _exitNonReentrant();
    }

    /// @dev Trigger auto-close via FixedMaturityModule.autoCloseFunding() (best-effort).
    ///      autoCloseFunding() is a no-op if conditions are no longer valid (race-safe).
    function _triggerAutoClose() private {
        // Call autoCloseFunding() via this vault's routing. Best-effort: ignore revert.
        address(this).call(abi.encodeWithSignature("autoCloseFunding()"));
    }

    /// @dev Mint exact shares. Gross-up: user pays grossAssets = ceil(netAssets * 10000 / (10000 - depBps)).
    ///      Fee computed as mulBpsDown(grossAssets, depBps) — SAME basis as _depositInternal.
    ///      This ensures identical fee shares to feeCollector regardless of deposit/mint path.
    ///      Ordering identical to _depositInternal: transferFrom → mint user → mint fee.
    function _mintInternal(uint256 shares, address receiver, address payer)
        internal
        returns (uint256 assets)
    {
        _checkDepositsAllowed(FixedMaturityStorage.layout());
        _notPausedDeposits();
        _enterNonReentrant();

        if (shares == 0) revert ZeroAmount();
        _ensureFreshWarmNav();

        CoreStorage.Layout storage core = CoreStorage.layout();
        FeeStorage.Layout storage f = FeeStorage.layout();

        // netAssets = assets needed to obtain S shares (without fee)
        // ceil(shares * totalAssets / totalSupply) — rounds UP for mint
        uint256 netAssets;
        {
            uint256 ts = IERC20(address(this)).totalSupply();
            uint256 ta = IERC4626(address(this)).totalAssets();
            if (ts > 0 && ta > 0) {
                netAssets = (shares * ta + ts - 1) / ts;
            } else {
                netAssets = _convertToAssets(shares);
            }
        }

        // Gross-up: G = ceil(N * 10000 / (10000 - f))
        // Fee computed algebraically to match deposit path exactly.
        // In deposit: sharesFee/userShares = depBps / (10000 - depBps)
        // So: sharesFee = shares * depBps / (10000 - depBps), rounded down.
        // This avoids the roundtrip divergence from grossAssets reverse computation.
        uint256 grossAssets;
        uint256 sharesFee;
        if (f.fee.depBps > 0) {
            uint256 denom = 10000 - uint256(f.fee.depBps);
            grossAssets = (netAssets * 10000 + denom - 1) / denom;
            // Direct algebraic fee shares — no roundtrip conversion
            sharesFee = shares * uint256(f.fee.depBps) / denom;
        } else {
            grossAssets = netAssets;
            sharesFee = 0;
        }

        _enforceDepositLimits(core, receiver, grossAssets, netAssets);

        // Transfer gross from payer
        IERC20(_asset()).safeTransferFrom(payer, address(this), grossAssets);

        // Mint GROSS shares to receiver, then TRANSFER fee to feeCollector.
        // NON-DILUTIVE: matches _depositInternal pattern.
        _processorMint(receiver, shares + sharesFee);
        core.lastDepositTs[receiver] = uint64(block.timestamp);

        if (sharesFee > 0) {
            _processorTransfer(receiver, core.feeCollector, sharesFee);
        }
        uint256 feeA = grossAssets - netAssets;
        emit Events.DepositFeeTaken(payer, feeA, sharesFee);
        emit IERC4626.Deposit(payer, receiver, grossAssets, shares);

        // Return gross assets paid (user's total cost)
        assets = grossAssets;

        _exitNonReentrant();
    }

    function _enforceDepositLimits(
        CoreStorage.Layout storage core,
        address receiver,
        uint256 grossAssets,
        uint256 creditedAssets
    ) internal view {
        if (address(core.params) == address(0)) return;

        IParamsProvider.DepositLimits memory limits =
            core.params.getDepositLimits(address(this));

        if (limits.minDepositAmount > 0 && grossAssets < limits.minDepositAmount) {
            revert DepositBelowMinimum(grossAssets, limits.minDepositAmount);
        }

        if (limits.vaultDepositCap > 0) {
            uint256 totalAssetsAfter = IERC4626(address(this)).totalAssets() + grossAssets;
            if (totalAssetsAfter > limits.vaultDepositCap) {
                revert VaultDepositCapExceeded(totalAssetsAfter, limits.vaultDepositCap);
            }
        }

        if (limits.userDepositCap > 0) {
            uint256 userAssetsAfter =
                IERC4626(address(this)).convertToAssets(IERC20(address(this)).balanceOf(receiver))
                + creditedAssets;
            if (userAssetsAfter > limits.userDepositCap) {
                revert UserDepositCapExceeded(userAssetsAfter, limits.userDepositCap);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: NAV VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Ensures fresh warm NAV for deposit/mint — auto-refreshes if stale
    function _ensureFreshWarmNav() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;

        if (address(bm) == address(0)) revert NavInvalid();

        (, uint40 ts, bool valid) = bm.warmNavState();

        if (block.timestamp > ts + MAX_WARM_NAV_AGE) {
            try bm.refreshWarmNav() {} catch {}
            (, ts, valid) = bm.warmNavState();
        }

        if (!valid) revert NavInvalid();
        if (block.timestamp > ts + MAX_WARM_NAV_AGE) revert NavStale();
    }

    /// @notice Best-effort soft refresh for exit paths (W2 = never block exits)
    /// @dev GUARANTEED non-reverting. If refresh fails → silently ignored.
    function _trySoftRefreshWarmNav() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;
        if (address(bm) == address(0)) return;

        (, uint40 ts,) = bm.warmNavState();
        if (block.timestamp > ts + MAX_WARM_NAV_AGE) {
            try bm.refreshWarmNav() {} catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: MODIFIERS AS FUNCTIONS (for delegatecall context)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _notPausedDeposits() internal view {
        uint256 flags = CoreStorage.layout().packedFlags;
        if (flags & CoreStorage.FLAG_PAUSED != 0) revert Paused();
        if (flags & CoreStorage.FLAG_PAUSED_DEPOSITS != 0) revert DepositsPaused();
    }

    function _notPausedWithdrawals() internal view {
        uint256 flags = CoreStorage.layout().packedFlags;
        if (flags & CoreStorage.FLAG_PAUSED != 0) revert Paused();
        if (flags & CoreStorage.FLAG_PAUSED_WITHDRAWALS != 0) revert WithdrawalsPaused();
    }

    function _enterNonReentrant() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        core.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    function _exitNonReentrant() internal {
        CoreStorage.layout().packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL: VAULT INTERFACE CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════════

    function _asset() internal view returns (address) {
        return IERC4626(address(this)).asset();
    }

    /// @dev Raw asset-to-share conversion WITHOUT deposit fee.
    ///      Used internally where fee is already deducted from `assets`.
    ///      The public previewDeposit() includes fee deduction for ERC4626 compliance.
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(this)).convertToShares(assets);
    }

    function _previewMint(uint256 shares) internal view returns (uint256) {
        return IERC4626(address(this)).previewMint(shares);
    }

    function _previewWithdraw(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(this)).previewWithdraw(assets);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return IERC4626(address(this)).convertToAssets(shares);
    }

    function _balanceOf(address account) internal view returns (uint256) {
        return IERC20(address(this)).balanceOf(account);
    }

    function _processorMint(address to, uint256 amount) internal {
        ICoreVault(address(this)).processorMint(to, amount);
    }

    function _processorBurn(address from, uint256 amount) internal {
        ICoreVault(address(this)).processorBurn(from, amount);
    }

    function _processorSpendAllowance(address owner_, address spender, uint256 amount) internal {
        ICoreVault(address(this)).processorSpendAllowance(owner_, spender, amount);
    }

    function _processorTransfer(address from, address to, uint256 amount) internal {
        ICoreVault(address(this)).processorTransfer(from, to, amount);
    }

    function _notifyIncentivesDeposit(
        address receiver,
        uint256 net,
        CoreStorage.Layout storage core
    ) internal {
        // Legacy incentives (backward compat)
        IIncentives inc = core.incentives;
        if (address(inc) != address(0)) {
            uint256 balance = _balanceOf(receiver);
            uint256 assets = _convertToAssets(balance);
            try inc.onDeposit(receiver, net * 1e12, assets * 1e12) {}
            catch (bytes memory reason) {
                emit Events.IncentivesOnDepositFailed(receiver, reason);
            }
        }

        // IncentivesEngine v2 (tranche-based)
        IIncentivesEngine eng = core.incentivesEngine;
        if (address(eng) != address(0)) {
            try eng.onDeposit(receiver, net * 1e12) {} catch {}
        }
    }

    /// @dev Notify IncentivesEngine on exit. Called BEFORE shares burned.
    ///      Assets-based (never shares). Try/catch — never blocks exits (W2).
    function _notifyIncentivesExit(
        address user,
        uint256 assetsExited,
        CoreStorage.Layout storage core
    ) internal {
        IIncentivesEngine eng = core.incentivesEngine;
        if (address(eng) == address(0)) return;

        try eng.onExit(user, assetsExited * 1e12) {} catch {}
    }
}
