// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { CoreStorage } from "../../src/core/storage/CoreStorage.sol";
import { FeeStorage } from "../../src/core/storage/FeeStorage.sol";
import { QueueStorage } from "../../src/core/storage/QueueStorage.sol";
import { IIncentives } from "../../src/interfaces/IIncentives.sol";
import { IIncentivesEngine } from "../../src/interfaces/IIncentivesEngine.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../../src/interfaces/IStrategyRouter.sol";
import { IParamsProvider } from "../../src/interfaces/IParamsProvider.sol";
import { StrategyRouter } from "../../src/core/modules/StrategyRouter.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";
import { LiquidityOpsModule } from "../../src/core/modules/LiquidityOpsModule.sol";
import { MockBufferManagerForTests } from "./MockBufferManagerForTests.sol";

/// @title CoreHarness
/// @notice Test harness for the new Diamond-lite CoreVault
/// @dev Provides unsafe setters for testing and wires up modules automatically
contract CoreHarness is CoreVault {
    uint16 private _opsTargetBps = 300; // 3%
    uint16 private _opsFloorBps = 100; // 1%

    // Track deployed modules for selector registration
    QueueModule public queueModule;
    AdminModule public adminModule;
    ERC4626Module public erc4626Module;
    LiquidityOpsModule public liquidityOpsModule;

    constructor(
        IERC20Metadata assetUSDC,
        string memory name_,
        string memory symbol_,
        address owner_,
        address treasury_,
        address params_
    )
        CoreVault(
            assetUSDC,
            name_,
            symbol_,
            owner_,
            treasury_, // feeCollector
            params_
        )
    {
        // Deploy modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();
        erc4626Module = new ERC4626Module();
        liquidityOpsModule = new LiquidityOpsModule();

        // Wire up queue module selectors (PUBLIC)
        _setModuleUnsafe(QueueModule.requestClaim.selector, address(queueModule), ROLE_PUBLIC);
        _setModuleUnsafe(QueueModule.cancelClaim.selector, address(queueModule), ROLE_PUBLIC);
        _setModuleUnsafe(
            QueueModule.processQueuedRedemptions.selector, address(queueModule), ROLE_PUBLIC
        );
        _setModuleUnsafe(
            QueueModule.settleFeesAndProcessQueue.selector, address(queueModule), ROLE_PUBLIC
        );
        _setModuleUnsafe(
            QueueModule.endEpochCrystallize.selector, address(queueModule), ROLE_PUBLIC
        );
        _setModuleUnsafe(QueueModule.pendingShares.selector, address(queueModule), ROLE_PUBLIC);
        _setModuleUnsafe(QueueModule.queueLength.selector, address(queueModule), ROLE_PUBLIC);
        _setModuleUnsafe(QueueModule.nextClaimId.selector, address(queueModule), ROLE_PUBLIC);
        _setModuleUnsafe(QueueModule.compactQueue.selector, address(queueModule), ROLE_PUBLIC);

        // Wire up admin module owner selectors (OWNER)
        _setModuleUnsafe(AdminModule.submitFeeParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.acceptFeeParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.revokeFeeParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.submitPerfParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.acceptPerfParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.revokePerfParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.submitMinDelay.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.acceptMinDelay.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.revokeMinDelay.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setParams.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setBufferManager.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setRouter.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setHealthRegistry.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setIncentives.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setFeeCollector.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.setVetoer.selector, address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.freezeParams.selector, address(adminModule), ROLE_OWNER);

        // Wire up admin module view selectors (PUBLIC)
        _setModuleUnsafe(
            AdminModule.getPendingFeeParams.selector, address(adminModule), ROLE_PUBLIC
        );
        _setModuleUnsafe(
            AdminModule.getPendingPerfParams.selector, address(adminModule), ROLE_PUBLIC
        );
        _setModuleUnsafe(AdminModule.getPendingMinDelay.selector, address(adminModule), ROLE_PUBLIC);
        _setModuleUnsafe(AdminModule.getFeeParams.selector, address(adminModule), ROLE_PUBLIC);
        _setModuleUnsafe(AdminModule.getPerfParams.selector, address(adminModule), ROLE_PUBLIC);
        _setModuleUnsafe(AdminModule.getMinDelay.selector, address(adminModule), ROLE_PUBLIC);
        _setModuleUnsafe(AdminModule.isParamsFrozen.selector, address(adminModule), ROLE_PUBLIC);

        // Wire up ERC4626Module selectors (PUBLIC) — required for deposit/withdraw
        // Use raw selectors for overloaded functions
        _setModuleUnsafe(bytes4(keccak256("deposit(uint256,address)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("deposit(uint256,address,uint256)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("depositFor(uint256,address,address)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("mint(uint256,address)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("mint(uint256,address,uint256)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("withdraw(uint256,address,address)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("withdraw(uint256,address,address,uint256)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("redeem(uint256,address,address)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(bytes4(keccak256("redeem(uint256,address,address,uint256)")), address(erc4626Module), ROLE_PUBLIC);
        _setModuleUnsafe(ERC4626Module.forceWithdrawAll.selector, address(erc4626Module), ROLE_PUBLIC);

        // Wire up LiquidityOpsModule selectors
        // deployToStrategiesWithPlan is ROLE_OWNER_OR_GUARDIAN: caller-supplied plans
        // control allocation across strategies and must not be permissionless.
        _setModuleUnsafe(LiquidityOpsModule.canDeploy.selector, address(liquidityOpsModule), ROLE_PUBLIC);
        _setModuleUnsafe(LiquidityOpsModule.deployToStrategies.selector, address(liquidityOpsModule), ROLE_PUBLIC);
        _setModuleUnsafe(
            LiquidityOpsModule.deployToStrategiesWithPlan.selector,
            address(liquidityOpsModule),
            ROLE_OWNER_OR_GUARDIAN
        );
        _setModuleUnsafe(LiquidityOpsModule.realizeForQueue.selector, address(liquidityOpsModule), ROLE_PUBLIC);
        _setModuleUnsafe(
            LiquidityOpsModule.realizeForReserveAndOps.selector,
            address(liquidityOpsModule),
            ROLE_PUBLIC
        );
        _setModuleUnsafe(
            LiquidityOpsModule.canRebalanceStrategies.selector,
            address(liquidityOpsModule),
            ROLE_PUBLIC
        );
        _setModuleUnsafe(
            LiquidityOpsModule.rebalanceStrategies.selector,
            address(liquidityOpsModule),
            ROLE_PUBLIC
        );

        // Authorize module for internal calls
        CoreStorage.Layout storage cs = CoreStorage.layout();
        cs.isAuthorizedModule[address(erc4626Module)] = true;

        // V8: CoreVault starts paused — unpause for testing
        cs.packedFlags &= ~(CoreStorage.FLAG_PAUSED | CoreStorage.FLAG_PAUSED_DEPOSITS | CoreStorage.FLAG_PAUSED_WITHDRAWALS);

        // Wire default MockBufferManager so deposit() doesn't revert NavInvalid.
        // Tests that need a real BM can override via setBufferManagerUnsafe().
        MockBufferManagerForTests defaultBm = new MockBufferManagerForTests(address(this));
        cs.bufferManager = IBufferManager(address(defaultBm));
    }

    // Internal helper to set module without routing frozen check
    function _setModuleUnsafe(bytes4 selector, address module, uint8 role) internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.moduleOf[selector] = module;
        core.roleOf[selector] = role;
    }

    // ---- Testing helpers to wire router/strategies ----
    function _ensureRouter() internal {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (address(core.router) == address(0)) {
            StrategyRouter r =
                new StrategyRouter(address(this), address(this), address(core.params));
            core.router = IStrategyRouter(address(r));
        }
    }

    function addStrategyUnsafe(address strat) external {
        _ensureRouter();
        CoreStorage.Layout storage core = CoreStorage.layout();
        StrategyRouter(address(core.router)).register(strat, 0, 10000);
    }

    function setIntakeUnsafe(address strat) external {
        _ensureRouter();
        CoreStorage.Layout storage core = CoreStorage.layout();
        StrategyRouter rm = StrategyRouter(address(core.router));
        rm.setIntakeMode(IStrategyRouter.IntakeMode.WEIGHTED);
        IStrategyRouter.StrategyInfo[] memory L = rm.list();
        uint256 n = L.length;
        address[] memory ss = new address[](n);
        uint16[] memory ww = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            ss[i] = L[i].strat;
            ww[i] = (L[i].strat == strat) ? 10000 : 0;
        }
        rm.setWeights(ss, ww);
    }

    function setBufferManagerUnsafe(address m) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = IBufferManager(m);
        IBufferManager.BufferConfig memory cfg = bm.getConfig();
        if (cfg.asset != address(0)) {
            require(cfg.asset == address(asset()), "bm-asset-mismatch");
        }
        core.bufferManager = bm;
    }

    function setStrategyRouterUnsafe(address r) external {
        CoreStorage.layout().router = IStrategyRouter(r);
    }

    function setGuardianUnsafe(address g) external {
        CoreStorage.layout().guardian = g;
    }

    // ---- Ops reserve params (for tests expectations) ----
    function opsReserveTargetBps() external view returns (uint16) {
        return _opsTargetBps;
    }

    function opsReserveFloorBps() external view returns (uint16) {
        return _opsFloorBps;
    }

    function setOpsUnsafe(uint16 targetBps, uint16 floorBps) external {
        _opsTargetBps = targetBps;
        _opsFloorBps = floorBps;
    }

    // ---- Fee params helpers ----
    function setFeeParamsUnsafe(uint16 depBps, uint16 witBps, address treasury) external {
        FeeStorage.Layout storage f = FeeStorage.layout();
        f.fee.depBps = depBps;
        f.fee.witBps = witBps;
        f.fee.treasury = treasury;
    }

    function setExitFeesUnsafe(uint16 witBps, uint16 immPenBps, uint16 forcePenBps) external {
        FeeStorage.Layout storage f = FeeStorage.layout();
        f.fee.witBps = witBps;
        f.fee.immediateExitPenaltyBps = immPenBps;
        f.fee.forceExitPenaltyBps = forcePenBps;
    }

    function setPerfParamsUnsafe(uint256 rateX, uint64 minInterval) external {
        FeeStorage.Layout storage f = FeeStorage.layout();
        f.perfRateX = rateX;
        f.minCrystallizeInterval = minInterval;
    }

    // ---- IParamsProvider functions (for StrategyRouter) ----
    function fees() external view returns (uint16 dBps, uint16 wBps, uint16 pBps) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        dBps = f.fee.depBps;
        wBps = f.fee.witBps;
        pBps = uint16(f.perfRateX / 1e14);
    }

    function vaultDepositCap() external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxActionsPerBatch() external pure returns (uint8) {
        return 10;
    }

    function isAdapterAllowed(address) external pure returns (bool) {
        return true;
    }

    function adapterCap(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function minRebalanceCooldown() external pure returns (uint256) {
        return 0;
    }

    function maxNavDeltaBps() external pure returns (uint16) {
        return 500;
    }

    function oracleFor(address) external pure returns (address) {
        return address(0);
    }

    function maxStaleness() external pure returns (uint256) {
        return 1 hours;
    }

    // ---- View helpers ----
    function pricePerShare() public view returns (uint256) {
        uint256 ts = totalSupply();
        if (ts == 0) return 1e18;
        uint256 ta = totalAssets();
        return (ta * 1e30) / ts;
    }

    // ---- Incentives wiring and wrappers for tests ----
    function setIncentivesUnsafe(address mod, bool active) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        core.incentives = IIncentives(mod);
        try IIncentives(mod).setCore(address(this)) { } catch { }
        try IIncentives(mod).setActive(active) { } catch { }
    }

    function claimBonus() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        require(address(core.incentives) != address(0), "no-incentives");
        uint256 userShares = balanceOf(msg.sender);
        uint256 userAssets = convertToAssets(userShares);
        uint256 userAssetsWad = userAssets * 1e12;
        core.incentives.claimAndCreateVesting(msg.sender, userAssetsWad);
    }

    function withdrawVested(uint256 idx, uint256 amountWad)
        external
        returns (uint256 sharesMinted)
    {
        CoreStorage.Layout storage core = CoreStorage.layout();
        require(address(core.incentives) != address(0), "no-incentives");
        uint256 paidWad = core.incentives.withdrawVested(msg.sender, idx, amountWad);
        if (paidWad == 0) return 0;
        uint256 pps = pricePerShare();
        sharesMinted = (paidWad * 1e18) / pps;
        _mint(msg.sender, sharesMinted);
    }

    // ---- Test helpers for lock period ----
    function setLockUnsafe(uint64 _lockPeriod) external {
        // Lock period is now in params provider, but we can store locally for legacy tests
        // This is a no-op for the new architecture as lock comes from params
    }

    function eligibleScheduledSharesNow(address user) external view returns (uint256) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IParamsProvider.WithdrawalParams memory wp = core.params.getWithdrawalParams(address(this));
        if (wp.lockPeriod == 0) return balanceOf(user);
        if (block.timestamp < uint256(core.lastDepositTs[user]) + wp.lockPeriod) return 0;
        return balanceOf(user);
    }

    function minClaimShares() external pure returns (uint256) {
        return 1;
    }

    // ---- Queue view helpers ----
    function queueLength() external view returns (uint256) {
        QueueStorage.Layout storage q = QueueStorage.layout();
        return q.queue.length > q.head ? q.queue.length - q.head : 0;
    }

    function pendingShares() external view returns (uint256) {
        return QueueStorage.layout().pendingShares;
    }

    // ---- Legacy compatibility (for old tests expecting these) ----
    function pause() external onlyOwner {
        CoreStorage.layout().packedFlags |= CoreStorage.FLAG_PAUSED;
    }

    function unpause() external onlyOwner {
        CoreStorage.layout().packedFlags &= ~CoreStorage.FLAG_PAUSED;
    }

    // ---- Epoch duration setter (ExitEngineLib tests) ----
    function setEpochDurationUnsafe(uint64 dur) external {
        CoreStorage.layout().epochDuration = dur;
    }

    function setParamMinDelayUnsafe(uint64 delay) external {
        CoreStorage.layout().paramMinDelay = delay;
    }

    function setRewardsPayoutManagerUnsafe(address manager) external {
        CoreStorage.layout().rewardsPayoutManager = manager;
    }

    function setIncentivesEngineUnsafe(address engine) external {
        CoreStorage.layout().incentivesEngine = IIncentivesEngine(engine);
    }

    // Note: Queue module functions (requestClaim, cancelClaim, processQueuedRedemptions,
    // settleFeesAndProcessQueue) are available via fallback routing to QueueModule
}
