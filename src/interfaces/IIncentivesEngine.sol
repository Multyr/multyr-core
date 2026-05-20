// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IIncentivesEngine — Tranche-Based Incentives Accounting
/// @notice ACCOUNTING ONLY. Does not move assets, mint shares, or transfer tokens.
///         All amounts in WAD (1e18). Payout handled by RewardsPayoutManager.
interface IIncentivesEngine {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    enum RewardMode { VaultShares, MultyrToken, Usdc }

    struct IncentiveParams {
        uint32 cliffDays;
        uint32 fullDays;
        uint32 vestingDays;
        uint128 bmaxWad;
        RewardMode rewardMode;
        bool active;
        uint64 effectiveFrom;
    }

    struct DepositTranche {
        uint128 principalWad;
        uint64 depositTs;
        uint64 lastAccrualTs;
        uint32 paramsId;
        bool active;
    }

    struct RewardVestingTranche {
        uint128 rewardUnits;
        uint64 vestStart;
        uint32 vestDurationDays;
        uint128 withdrawnUnits;
        uint32 paramsId;
        RewardMode mode;
        uint128 conversionRatio;
        bool active;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event TrancheCreated(address indexed user, uint256 idx, uint128 principalWad, uint32 paramsId);
    event TrancheConsumed(address indexed user, uint256 idx, uint128 consumedWad);
    event TranchesConsolidated(address indexed user, uint256 mergedCount, uint256 remainingCount);
    event RewardAccrued(address indexed user, uint128 rewardUnitsWad);
    event RewardVestingCreated(address indexed user, uint256 idx, uint128 rewardUnits, RewardMode mode);
    event RewardSlashed(address indexed user, uint256 vestingIdx, uint128 slashedUnits);
    event RewardWithdrawn(address indexed user, uint256 vestingIdx, uint128 paidUnits);
    event ParamsUpdated(uint32 newParamsId, IncentiveParams params);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event TrancheCountWarning(address indexed user, uint256 count, uint256 threshold);
    event AutoConsolidationTriggered(address indexed user, uint256 beforeCount, uint256 afterCount);

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE HOOKS (called by CoreVault modules via try/catch)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Called after deposit. Creates a new DepositTranche.
    /// @param user The depositor
    /// @param addedAssetsWad Assets deposited in WAD (1e18)
    function onDeposit(address user, uint256 addedAssetsWad) external;

    /// @notice Called before exit (any path). Syncs incentives: auto-claim, FIFO consume, slash.
    /// @param user The exiting user
    /// @param assetsExitedWad Assets exiting in WAD (1e18)
    /// @return vestedUnits Informational: reward units vested to user
    /// @return slashedUnits Informational: reward units slashed to treasury
    function onExit(address user, uint256 assetsExitedWad)
        external
        returns (uint256 vestedUnits, uint256 slashedUnits);

    /// @notice O(1) light exit hook — records pending exit for later reconciliation.
    /// @param user The exiting user
    /// @param assetsExitedWad Assets exiting in WAD (1e18)
    function onExitLight(address user, uint256 assetsExitedWad) external;

    /// @notice Process pending exit records (heavy, called by keeper).
    /// @param maxUsers Maximum number of pending exits to process
    /// @return processed Number of exits actually processed
    function reconcilePendingExits(uint256 maxUsers) external returns (uint256 processed);

    /// @notice Returns the number of pending exit records awaiting reconciliation.
    function pendingExitCount() external view returns (uint256);

    /// @notice Governance escape hatch — skip a stuck pending exit at head.
    /// @param pendingId Must equal pendingHead
    function skipFailedReconcile(uint256 pendingId) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // USER ACTIONS (pull model)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Claim accrued reward into a vesting tranche. User-initiated.
    /// @param user The user claiming
    /// @return claimed Total reward units claimed
    function claimAndCreateVesting(address user) external returns (uint256 claimed);

    /// @notice Withdraw vested reward from a specific tranche. User-initiated.
    /// @param user The user withdrawing
    /// @param vestingIdx Index of the reward vesting tranche
    /// @param amount Amount of reward units to withdraw
    /// @return paid Amount actually paid
    /// @return mode Reward mode of this tranche (for payout conversion)
    /// @return conversionRatio Fixed conversion ratio (for MultyrToken)
    function withdrawVested(address user, uint256 vestingIdx, uint256 amount)
        external
        returns (uint256 paid, RewardMode mode, uint128 conversionRatio);

    // ═══════════════════════════════════════════════════════════════════════════
    // MAINTENANCE (permissionless)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Compact user tranches (merge matured, remove tombstones). Callable by anyone.
    function consolidateTranches(address user) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE (vault timelock only)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update incentive parameters. Non-retroactive: new paramsId for new tranches only.
    function setParams(IncentiveParams calldata newParams) external;

    /// @notice Set core vault address
    function setCore(address core_) external;

    /// @notice Set treasury address (slash recipient)
    function setTreasury(address treasury_) external;

    /// @notice Transfer governance to new address
    function transferGovernance(address newGovernance) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function core() external view returns (address);
    function treasury() external view returns (address);
    function governance() external view returns (address);
    function currentParamsId() external view returns (uint32);
    function getParams(uint32 paramsId) external view returns (IncentiveParams memory);
    function getCurrentParams() external view returns (IncentiveParams memory);

    function getUserTranches(address user) external view returns (DepositTranche[] memory);
    function getUserVestings(address user) external view returns (RewardVestingTranche[] memory);
    function pendingReward(address user) external view returns (uint256 totalPendingWad);
    function vestedAvailable(address user, uint256 vestingIdx) external view returns (uint256);
    function trancheCount(address user) external view returns (uint256);
    function vestingCount(address user) external view returns (uint256);
}
