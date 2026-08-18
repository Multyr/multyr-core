// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../interfaces/IStrategyRouter.sol";
import { IStrategyHealthRegistry } from "../../interfaces/IStrategyHealthRegistry.sol";
import { IIncentives } from "../../interfaces/IIncentives.sol";
import { IIncentivesEngine } from "../../interfaces/IIncentivesEngine.sol";

/// @title CoreStorage
/// @notice Namespaced storage for CoreVault - shared by all modules via delegatecall
/// @dev Uses EIP-7201 style storage location to prevent collisions
library CoreStorage {
    // keccak256(abi.encode(uint256(keccak256("dsf.core.main.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT =
        0xff7b491291207fbb51df1ab8f042e8ee7f087c9a7e4a083e1a2dbbddb742ef00;

    // Epoch duration bounds
    uint64 internal constant MIN_EPOCH_DURATION = 1 days;
    uint64 internal constant MAX_EPOCH_DURATION = 30 days;

    // Flag constants for _packedFlags
    uint256 internal constant FLAG_PAUSED = 1 << 0;
    uint256 internal constant FLAG_PAUSED_DEPOSITS = 1 << 1;
    uint256 internal constant FLAG_PAUSED_WITHDRAWALS = 1 << 2;
    uint256 internal constant FLAG_PARAMS_FROZEN = 1 << 3;
    uint256 internal constant FLAG_LIQUIDITY_LOCKED = 1 << 4;
    uint256 internal constant FLAG_NAV_SMOOTH_INIT = 1 << 5;
    uint256 internal constant FLAG_ROUTING_FROZEN = 1 << 6;
    uint256 internal constant FLAG_REENTRANCY_LOCKED = 1 << 7;
    uint256 internal constant FLAG_COMPONENTS_TIMELOCKED = 1 << 8;
    uint256 internal constant FLAG_SYSTEM_SEALED = 1 << 9;
    uint256 internal constant FLAG_DEAD_DEPOSIT_DONE = 1 << 10;
    uint256 internal constant FLAG_FEES_INITIALIZED = 1 << 11;
    uint256 internal constant FLAG_PERF_INITIALIZED = 1 << 12;

    // Granular withdrawal circuit breakers (review §20/§21: FLAG_PAUSED_WITHDRAWALS is too
    // coarse — it must not be able to block funded claims or new queued-exit requests, and
    // force exit must never be gated by a generic emergency flag at all).
    uint256 internal constant FLAG_INSTANT_WITHDRAWAL_PAUSED = 1 << 13;
    uint256 internal constant FLAG_QUEUED_REQUEST_PAUSED = 1 << 14;
    uint256 internal constant FLAG_EPOCH_CLOSE_FUND_PAUSED = 1 << 15;
    uint256 internal constant FLAG_FUNDED_CLAIM_PAUSED = 1 << 16;
    uint256 internal constant FLAG_FORCE_EXIT_PAUSED = 1 << 17;

    struct Layout {
        // Addresses (each 20 bytes, separate slots for simplicity)
        IParamsProvider params;
        IBufferManager bufferManager;
        IStrategyRouter router;
        IStrategyHealthRegistry healthRegistry;
        IIncentives incentives;
        address feeCollector;
        address vetoer;
        address guardian;
        address owner;
        address pendingOwner;

        // Packed flags + timestamps
        // TODO: check if packedFlags could be uint64 that would fit all flags and save some gas,
        // @dev but uint256 is more future-proof for adding flags without worrying about overflow
        uint256 packedFlags;
        uint64 epochStart;
        uint64 lastGuardianPause;
        uint64 paramMinDelay;

        // Epoch tracking
        uint256 epochWithdrawn;
        uint64 currentEpochNumber;
        uint64 epochDuration;
        uint64 lastEpochReset;

        // TVL tracking
        uint256 lastRecordedTVL;
        uint64 lastTVLSnapshot;

        // NAV smoothing
        uint256 navSmooth;
        uint64 lastNavSmoothUpdate;

        // Mappings
        mapping(address => uint64) lastDepositTs;
        mapping(uint256 => uint256) blockWithdrawals;
        mapping(address => uint64) userLastClaimEpoch;
        mapping(address => uint8) userClaimsCount;
        mapping(address => uint64) userLastClaimTime;

        // Module routing
        mapping(bytes4 => address) moduleOf;
        mapping(bytes4 => uint8) roleOf; // 0=PUBLIC, 1=OWNER, 2=GUARDIAN, 3=OWNER_OR_GUARDIAN

        // Selector registry for role validation (set once, immutable)
        address selectorRegistry;

        // System sealer binding - set atomically by sealBySealer() (called from
        // SystemSealer.verifyAndSeal()) alongside FLAG_SYSTEM_SEALED, in the same call
        // that verifies the config hash. Retained post-seal as an audit record.
        bytes32 pendingSealHash;
        address authorizedSealer; // SystemSealer contract address (set once)

        // Module authorization mapping (for processor functions)
        // Modules authorized via authorizeModule() can call processorMint/processorBurn/etc
        mapping(address => bool) isAuthorizedModule;

        // Incentives Engine v2 (tranche-based, replaces IIncentives)
        IIncentivesEngine incentivesEngine;

        // Rewards Payout Manager (sole payout point for incentive rewards)
        address rewardsPayoutManager;

        // V10 Portfolio-Grade Allocation Engine (appended — Correction #2, Fixes #1-3)
        // Policy builds RebalancePlans, Guard evaluates them, ExecutionMemory tracks costs.
        address rebalancePolicy;
        address rebalanceGuard;
        address executionMemory;
        bool    strictExecutionMemory;

        // Rewards Treasury (appended): pre-funded share balance that payRewardShares()
        // transfers from. Reward payouts are non-dilutive by construction — no new
        // shares are minted, so PPS is unaffected. Funding this address is a
        // treasury-ops decision outside the vault's scope.
        address rewardsTreasury;

        // Emergency Module Recovery gate (appended, set once, immutable) — the
        // sole authorized caller of recoverModuleGroup(). Review §7/§8.
        address recoveryGate;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
