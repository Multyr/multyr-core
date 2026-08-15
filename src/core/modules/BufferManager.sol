// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { ICoreVault } from "../../interfaces/ICoreVault.sol";
import { IWarmAdapter } from "../../interfaces/IWarmAdapter.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title BufferManager
/// @notice Manages hot/warm buffer around target percentages. Core holds the asset; warm adapter holds deployed funds.
///         Deploy path requires Core to approve this contract to pull `asset` and transfer to the adapter.
///
/// @dev CRITICAL INVARIANT: BufferManager must NEVER hold idle asset balance.
///      All assets flow directly between CoreVault (hot) and WarmAdapters (warm).
///      This invariant ensures that cachedWarmNav = sum(adapter.totalAssets()) represents
///      100% of warm assets. If BM held idle assets, cachedWarmNav would undercount,
///      causing deposit() to mint too many shares (dilution attack).
///      See test: test_invariant_bufferManager_never_holds_idle_assets()
contract BufferManager is IBufferManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error NotCore();
    error NotKeeperOrCore();
    error Paused();
    error ZeroAddress();
    error AssetZero();
    error BpsOutOfRange();
    error WarmAdapterZero();
    error SlippageExceeded(); // C2: Warm withdraw slippage exceeded
    error InsufficientHot(uint256 hot, uint256 amount); // Solvency: cannot deploy more than hot balance

    // Bounds retries against a single adapter in _withdrawFromAdapterWithRetry() —
    // caps worst-case gas if an adapter dribbles out tiny amounts per call, while
    // comfortably covering realistic per-call-cap fragmentation (a handful of retries).
    uint8 private constant MAX_ADAPTER_WITHDRAW_ATTEMPTS = 8;

    // Graceful degradation event
    event RebalanceGracefulDegradation();

    // Fallback events
    event WarmDeploySuccess(address indexed adapter, uint256 amount);
    event WarmDeployFallbackUsed(
        address indexed primary, address indexed fallback_, uint256 amount
    );
    event WarmDeployAllFailed(uint256 amount);

    address public immutable core; // CoreVault address (hot holder)
    address public owner; // admin/guardian
    address public keeper; // FIX A: Authorized keeper (VaultUpkeep) for rebalance()

    BufferConfig private _cfg; // current config (includes paused flag)
    address[] private _warmAdapters; // A5: Array of warm adapters for diversification

    /// @notice Gas limit for warm adapter totalAssets() queries (V7: configurable, default 1.5M)
    uint32 public warmAdapterQueryGasLimit = 1_500_000;

    /// @notice FIX B: Rebalance cooldown and threshold for upkeep trigger
    uint40 public lastRebalanceTs;
    uint32 public rebalanceCooldown = 10 minutes;
    uint256 public minRebalanceAmount; // set in constructor: 5k asset-units, scaled by the vault asset's decimals

    /// @notice NAV refresh interval - trigger rebalance() just to refresh cache even if no funds to move
    /// @dev Must be less than CoreVault.MAX_WARM_NAV_AGE (15 min) to prevent deposit deadlock
    uint32 public navRefreshInterval = 10 minutes;

    /// @notice Cached warm NAV for O(1) pricing (updated by keeper in rebalance)
    /// @dev CoreVault uses this instead of warmBalance() to avoid OOG in deposit/mint
    uint256 public cachedWarmNav;
    uint40 public lastWarmNavUpdate;

    /// @notice Validity flag for cached warm NAV
    /// @dev If ANY adapter fails during cache update, this is set to false.
    ///      CoreVault MUST reject deposit/mint when warmNavValid=false.
    ///      This ensures no share is minted with incomplete/understated NAV.
    bool public warmNavValid;

    /// @notice Event emitted when cached warm NAV is updated
    event WarmNavCacheUpdated(uint256 warmNav, uint40 timestamp, bool valid);

    /// @notice Emitted when a warm adapter fails during NAV cache update (staticcall)
    /// @param adapter The adapter that failed
    /// @param success Whether the staticcall succeeded (false = revert, true but bad data)
    /// @param data The return data or revert reason
    event WarmNavAdapterFailed(address indexed adapter, bool success, bytes data);

    /// @notice Event emitted when keeper is updated
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event WarmAdapterQueryGasLimitUpdated(uint32 oldLimit, uint32 newLimit);

    /// @notice Event emitted when rebalance params are updated
    event RebalanceParamsUpdated(uint32 cooldown, uint256 minAmount, uint32 refreshInterval);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyCore() {
        if (msg.sender != core) revert NotCore();
        _;
    }
    /// @notice FIX A: Allows rebalance() to be called by keeper (VaultUpkeep) or core
    modifier onlyKeeperOrCore() {
        if (msg.sender != keeper && msg.sender != core) revert NotKeeperOrCore();
        _;
    }
    modifier notPaused() {
        if (_cfg.paused) revert Paused();
        _;
    }

    constructor(address owner_, address core_, BufferConfig memory cfg_) {
        if (owner_ == address(0) || core_ == address(0)) revert ZeroAddress();
        owner = owner_;
        core = core_;
        minRebalanceAmount = 5_000 * (10 ** IERC20Metadata(ICoreVault(core_).asset()).decimals());
        _setConfig(cfg_);
        // Initialize warm NAV cache - valid=true because no adapters configured yet (warm=0 is correct)
        // Keeper must call rebalance() within MAX_WARM_NAV_AGE to maintain freshness
        lastWarmNavUpdate = uint40(block.timestamp);
        warmNavValid = true; // No adapters = warm is correctly 0
    }

    // --- Admin ---
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Set the authorized keeper (VaultUpkeep) for rebalance()
    /// @dev FIX A: Only keeper or core can call rebalance() - audit-grade access control
    function setKeeper(address newKeeper) external onlyOwner {
        address oldKeeper = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(oldKeeper, newKeeper);
    }

    function setWarmAdapterQueryGasLimit(uint32 limit) external onlyOwner {
        require(limit >= 100_000 && limit <= 5_000_000, "invalid gas limit");
        uint32 old = warmAdapterQueryGasLimit;
        warmAdapterQueryGasLimit = limit;
        emit WarmAdapterQueryGasLimitUpdated(old, limit);
    }

    /// @notice Set rebalance cooldown and minimum amount threshold
    /// @dev FIX B: Used by canRebalance() to determine if upkeep should trigger rebalance
    function setRebalanceParams(uint32 cooldown, uint256 minAmount, uint32 refreshInterval)
        external
        onlyOwner
    {
        rebalanceCooldown = cooldown;
        minRebalanceAmount = minAmount;
        navRefreshInterval = refreshInterval;
        emit RebalanceParamsUpdated(cooldown, minAmount, refreshInterval);
    }

    function updateConfig(BufferConfig calldata cfg) external override onlyOwner {
        _setConfig(cfg);
        emit BufferConfigUpdated(cfg);
    }

    /// @notice Reset the full list of warm adapters (overwrites existing)
    function setWarmAdapters(address[] calldata adapters) external override onlyOwner {
        _clearWarmAdapters();
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len;) {
            address a = adapters[i];
            if (a == address(0)) revert ZeroAddress();
            // Validate adapter interface
            try IWarmAdapter(a).totalAssets() returns (uint256) { }
            catch {
                revert WarmAdapterZero();
            }
            _warmAdapters.push(a);
            emit WarmAdapterAdded(a, i);
            unchecked {
                ++i;
            }
        }
    }

    function setPaused(bool p) external override onlyOwner {
        _cfg.paused = p;
        emit BufferPaused(p);
    }

    function _setConfig(BufferConfig memory cfg) internal {
        if (cfg.asset == address(0)) revert AssetZero();
        if (cfg.targetHotBps > 1e4 || cfg.minHotBps > 1e4) revert BpsOutOfRange();
        if (cfg.maxWarmBps > 1e4 || cfg.targetWarmBps > 1e4) revert BpsOutOfRange();
        if (cfg.opsReserveTargetBps > 1e4) revert BpsOutOfRange(); // A3: validate ops reserve
        if (cfg.maxWarmSlippageBps > 500) revert BpsOutOfRange(); // C2: max 5% slippage

        // SECURITY: Validate warm adapter if provided
        if (cfg.warmAdapter != address(0)) {
            // Verify it implements IWarmAdapter interface by calling totalAssets()
            try IWarmAdapter(cfg.warmAdapter).totalAssets() returns (
                uint256
            ) {
            // Success - adapter is valid
            }
            catch {
                revert WarmAdapterZero(); // Reuse existing error for invalid adapter
            }
        }

        _cfg = cfg; // includes paused flag

        // Backward compat: if legacy warmAdapter is set and list is empty, seed it
        if (_warmAdapters.length == 0 && cfg.warmAdapter != address(0)) {
            _warmAdapters.push(cfg.warmAdapter);
            emit WarmAdapterAdded(cfg.warmAdapter, 0);
        }
    }

    // --- Views ---
    function getConfig() external view override returns (BufferConfig memory) {
        return _cfg;
    }

    function hotBalance() public view override returns (uint256) {
        address asset = _cfg.asset; // Cache storage to save ~1 SLOAD
        if (asset == address(0)) return 0; // unconfigured
        return IERC20(asset).balanceOf(core);
    }

    function warmBalance() public view override returns (uint256) {
        // A5: Sum balance across all warm adapters
        uint256 total = 0;
        uint256 len = _warmAdapters.length;

        // Backward compatibility: check legacy warmAdapter if set
        // BUT skip if it's already in the multi-adapters array (to avoid double-counting)
        address legacyWarm = _cfg.warmAdapter;
        bool legacyInArray = false;
        if (legacyWarm != address(0)) {
            // Check if legacy adapter is in the array
            for (uint256 i = 0; i < len;) {
                if (_warmAdapters[i] == legacyWarm) {
                    legacyInArray = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }

            // Only count legacy if not in array
            if (!legacyInArray) {
                try IWarmAdapter(legacyWarm)
                .totalAssets{ gas: warmAdapterQueryGasLimit }() returns (
                    uint256 bal
                ) {
                    total += bal;
                } catch {
                    // Skip failed adapter
                }
            }
        }

        // Sum all multi-adapters
        for (uint256 i = 0; i < len;) {
            try IWarmAdapter(_warmAdapters[i])
            .totalAssets{ gas: warmAdapterQueryGasLimit }() returns (
                uint256 bal
            ) {
                total += bal;
            } catch {
                // Skip failed adapter
            }
            unchecked {
                ++i;
            }
        }

        return total;
    }

    function totalBuffer() public view override returns (uint256) {
        return hotBalance() + warmBalance();
    }

    /// @notice Target hot balance computed on current NAV (post-event) as reported by Core.
    function targetHot() public view returns (uint256) {
        uint256 nav = ICoreVault(core).totalAssets();
        return (nav * _cfg.targetHotBps) / 1e4;
    }

    /// @dev Assets the vault has already promised to FUNDED-but-unclaimed epoch
    ///      claimants. Read through the vault's selector routing rather than a
    ///      typed interface so a core deployed without the epoch queue wired
    ///      (or an older core) degrades to "nothing reserved" instead of
    ///      bricking every buffer operation.
    function _reservedForClaims() internal view returns (uint256 reserved) {
        (bool ok, bytes memory data) =
            core.staticcall(abi.encodeWithSignature("reservedForClaims()"));
        if (ok && data.length == 32) reserved = abi.decode(data, (uint256));
    }

    function plan() public view override returns (uint256 needRefill, uint256 needDeploy) {
        BufferConfig memory cfg = _cfg; // Cache storage to save ~2 SLOADs

        // Single external call: gets nav, hot, and warm in one shot
        // This avoids redundant warmBalance() call when we need warm for maxWarmBps cap
        (uint256 nav, uint256 hot, uint256 warm) = ICoreVault(core).totalAssetsBreakdown();
        if (nav == 0) return (0, 0);

        // The buffer manages FREE liquidity only. Cash earmarked for
        // FUNDED-but-unclaimed epoch claims is not the buffer's to move: the
        // warm adapters pull it straight out of the vault under the standing
        // allowance from CoreVault.approveWarmAdapters(), which is a transfer
        // path no module-level reservation check can see. Netting it out here
        // shrinks needDeploy and grows needRefill, both in the safe direction.
        hot = hot > _reservedForClaims() ? hot - _reservedForClaims() : 0;

        uint256 targetHotAmt = (nav * cfg.targetHotBps) / 1e4;
        uint256 minHot = (nav * cfg.minHotBps) / 1e4;

        if (hot < minHot) {
            needRefill = targetHotAmt > hot ? (targetHotAmt - hot) : 0;
            return (needRefill, 0);
        }

        if (hot > targetHotAmt) {
            needDeploy = hot - targetHotAmt;
            // B2: Cap needDeploy to respect maxWarmBps
            if (cfg.maxWarmBps > 0) {
                uint256 maxWarm = (nav * cfg.maxWarmBps) / 1e4;
                uint256 availableWarmCapacity = maxWarm > warm ? (maxWarm - warm) : 0;
                if (needDeploy > availableWarmCapacity) {
                    needDeploy = availableWarmCapacity;
                }
            }
            return (0, needDeploy);
        }

        return (0, 0);
    }

    /// @notice FIX B: Check if rebalance should be triggered by upkeep
    /// @dev Returns true if:
    ///      1. Cooldown elapsed AND (needRefill OR needDeploy) >= minRebalanceAmount, OR
    ///      2. NAV cache is stale (beyond navRefreshInterval) - prevents deposit deadlock
    ///      This is O(1) in this contract; plan() calls CoreVault.totalAssetsBreakdown() which is view.
    function canRebalance() external view returns (bool) {
        // Check if paused
        if (_cfg.paused) {
            return false;
        }

        // LIVENESS FIX: Always trigger if NAV cache is stale, regardless of needRefill/needDeploy
        // This prevents deposit deadlock when system is in steady state (no funds to move)
        // but cache has expired. rebalance() will just refresh the cache.
        if (block.timestamp > uint256(lastWarmNavUpdate) + uint256(navRefreshInterval)) {
            return true;
        }

        // Check cooldown for normal rebalance operations
        if (block.timestamp < uint256(lastRebalanceTs) + uint256(rebalanceCooldown)) {
            return false;
        }

        // Get plan amounts
        (uint256 needRefill, uint256 needDeploy) = plan();

        // Trigger if either exceeds threshold
        return (needRefill >= minRebalanceAmount) || (needDeploy >= minRebalanceAmount);
    }

    /// @notice Get cached warm NAV state for O(1) staleness and validity check
    /// @dev Used by CoreVault.deposit()/mint() to enforce NAV freshness AND completeness
    /// @return nav Cached warm NAV value
    /// @return ts Timestamp when cache was last updated
    /// @return valid True if ALL adapters responded successfully during last cache update.
    ///               If false, deposit/mint MUST revert - NAV is incomplete.
    function warmNavState() external view returns (uint256 nav, uint40 ts, bool valid) {
        return (cachedWarmNav, lastWarmNavUpdate, warmNavValid);
    }

    // --- Ops ---
    function prepareDeploy() external view override returns (uint256 amount) {
        (, amount) = plan();
    }

    function executeDeploy(uint256 amount) external override nonReentrant onlyCore notPaused {
        if (amount == 0) return;

        // NOTE: maxWarmBps cap is enforced in plan(): executeDeploy assumes caller passes a capped amount.
        // Here we only ensure solvency (cannot deploy more than hot USDC held by the CoreVault).
        uint256 hot = hotBalance();
        if (hot < amount) revert InsufficientHot(hot, amount);

        if (_warmAdapters.length == 0) revert WarmAdapterZero();

        // Try adapters in order, stopping at the first success; funds stay hot if all fail.
        bool deployed = _deployToAdapters(amount);

        // Update warm NAV cache if deploy succeeded (warm balance changed)
        if (deployed) {
            _updateWarmNavCache();
        }
    }

    function refill(uint256 amount) external override nonReentrant onlyCore notPaused {
        if (amount == 0) return;
        BufferConfig memory cfg = _cfg; // Cache storage to save ~2 SLOADs

        // A5: Withdraw from legacy + multi-adapters (deduplicated) until filled or exhausted
        uint256 totalReceived = _withdrawFromAdapters(amount);

        // C2: Slippage protection - verify received amount
        if (cfg.maxWarmSlippageBps > 0 && totalReceived < amount) {
            uint256 slippageBps = ((amount - totalReceived) * 10000) / amount;
            if (slippageBps > cfg.maxWarmSlippageBps) {
                revert SlippageExceeded();
            }
        }

        // Update warm NAV cache after refill (warm balance changed)
        _updateWarmNavCache();

        emit BufferRefilled(totalReceived, 0);
    }

    /// @notice Force refill for forceWithdraw — deterministic, no silent failures.
    /// @dev Returns result instead of reverting. No slippage check (force path).
    ///      Called by ERC4626Module.forceWithdrawAll() via delegatecall.
    ///      INVARIANT: no adapter failure is hidden — shares `_withdrawFromAdapters()`
    ///      with refill()/rebalance()/realizeForReserveAndOps(), which retries each
    ///      adapter on partial fills and emits `WarmWithdrawAdapterFailed` on any
    ///      revert (see that function's docs). This function adds its own explicit
    ///      return value + `ForceRefillFailed` event on top for the total-failure case.
    function forceRefill(uint256 amount) external override nonReentrant onlyCore returns (bool ok, uint256 pulled) {
        if (amount == 0) return (true, 0);

        uint256 totalReceived = _withdrawFromAdapters(amount);

        // NO slippage check (force path)
        _updateWarmNavCache();

        if (totalReceived > 0) {
            emit BufferRefilled(totalReceived, 0);
            return (true, totalReceived);
        } else {
            emit ForceRefillFailed(amount);
            return (false, 0);
        }
    }

    event ForceRefillFailed(uint256 requested);

    /// @notice Rebalance hot/warm buffer. Callable by keeper (VaultUpkeep) or core.
    /// @dev FIX A: Changed from onlyCore to onlyKeeperOrCore for audit-grade access control.
    ///      FIX B: Updates lastRebalanceTs for cooldown check in canRebalance().
    ///      Security: rebalance() only moves funds between core and warm adapters,
    ///      never to msg.sender. refill() and executeDeploy() remain onlyCore.
    ///      Call setKeeper(vaultUpkeepAddress) to authorize the upkeep contract.
    function rebalance() external override nonReentrant onlyKeeperOrCore notPaused {
        // FIX B: Update timestamp for cooldown
        lastRebalanceTs = uint40(block.timestamp);
        (uint256 needRefill, uint256 needDeploy) = plan();
        BufferConfig memory cfg = _cfg; // Cache storage to save ~2 SLOADs

        if (needRefill > 0) {
            // A5: Multi-adapter refill (same deduplicated logic as refill())
            uint256 totalReceived = _withdrawFromAdapters(needRefill);

            // C2: Slippage protection — graceful degradation instead of revert
            if (cfg.maxWarmSlippageBps > 0 && totalReceived < needRefill) {
                uint256 slippageBps = ((needRefill - totalReceived) * 10000) / needRefill;
                if (slippageBps > cfg.maxWarmSlippageBps) {
                    // CRITICAL: update lastRebalanceTs so canRebalance() returns false during cooldown
                    _updateWarmNavCache();
                    lastRebalanceTs = uint40(block.timestamp);
                    emit RebalanceGracefulDegradation();
                    return;
                }
            }

            emit BufferRefilled(totalReceived, 0);
        } else if (needDeploy > 0) {
            // NOTE: maxWarmBps cap is enforced in plan() which computed needDeploy.
            // Here we only ensure solvency (cannot deploy more than hot balance).
            uint256 hot = hotBalance();
            if (hot < needDeploy) revert InsufficientHot(hot, needDeploy);

            if (_warmAdapters.length == 0) revert WarmAdapterZero();

            // Try adapters in order, stopping at the first success.
            _deployToAdapters(needDeploy);
        }

        // Update cached warm NAV after all operations
        // This is the ONLY place where cache is updated - keeper path only
        _updateWarmNavCache();
    }

    /// @notice Internal: Update cached warm NAV by iterating adapters with validity tracking
    /// @dev Called at end of rebalance() to ensure cache reflects current state.
    ///      CRITICAL: If ANY adapter fails, warmNavValid is set to false.
    ///      CoreVault MUST reject deposit/mint when warmNavValid=false.
    ///      Uses staticcall to guarantee read-only (no state modification during query).
    function _updateWarmNavCache() internal {
        uint256 total = 0;
        bool allOk = true;

        // Check legacy adapter if set and not in array
        address legacyWarm = _cfg.warmAdapter;
        bool legacyInArray = false;
        uint256 len = _warmAdapters.length;

        if (legacyWarm != address(0)) {
            for (uint256 i = 0; i < len;) {
                if (_warmAdapters[i] == legacyWarm) {
                    legacyInArray = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }

            if (!legacyInArray) {
                // Use staticcall to guarantee read-only query (defense-in-depth)
                (bool success, bytes memory data) = legacyWarm.staticcall{
                    gas: warmAdapterQueryGasLimit
                }(abi.encodeWithSelector(IWarmAdapter.totalAssets.selector));
                if (success && data.length >= 32) {
                    total += abi.decode(data, (uint256));
                } else {
                    // CRITICAL: Adapter failed - NAV is incomplete
                    allOk = false;
                    emit WarmNavAdapterFailed(legacyWarm, success, data);
                }
            }
        }

        // Iterate all multi-adapters using staticcall
        for (uint256 i = 0; i < len;) {
            (bool success, bytes memory data) = _warmAdapters[i]
            .staticcall{
                gas: warmAdapterQueryGasLimit
            }(abi.encodeWithSelector(IWarmAdapter.totalAssets.selector));
            if (success && data.length >= 32) {
                total += abi.decode(data, (uint256));
            } else {
                // CRITICAL: Adapter failed - NAV is incomplete
                allOk = false;
                emit WarmNavAdapterFailed(_warmAdapters[i], success, data);
            }
            unchecked {
                ++i;
            }
        }

        // Update cache state
        cachedWarmNav = total;
        lastWarmNavUpdate = uint40(block.timestamp);
        warmNavValid = allOk;

        emit WarmNavCacheUpdated(total, uint40(block.timestamp), allOk);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PERMISSIONLESS NAV CACHE REFRESH
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Permissionless warm NAV cache refresh — cache-maintenance primitive
    /// @dev Allows anyone (frontend, DepositRouter, EOA, CoreVault auto-refresh) to
    ///      update the warm NAV cache without moving funds or touching cooldowns.
    ///      Security contract: see docs/09-audit/nav-refresh-cost-analysis.md §2e
    ///      - No fund movement (S2)
    ///      - No router interaction (S3)
    ///      - No cooldown update (S4)
    ///      - Read-only adapter queries via staticcall (S5)
    ///      - Adapter failure → valid=false (S6)
    ///      - Caller-paid gas ~800K on Arbitrum (S8)
    function refreshWarmNav() external nonReentrant {
        _updateWarmNavCache();
    }

    /// @notice Top up hot to target by refilling from warm only.
    /// @dev Strategy realization is handled by LiquidityOpsModule after this warm step.
    function realizeForReserveAndOps(uint256 maxAmount)
        external
        nonReentrant
        onlyCore
        notPaused
        returns (uint256 pulled)
    {
        uint256 tgt = targetHot();
        uint256 hot = hotBalance();
        if (hot >= tgt || maxAmount == 0) return 0;
        uint256 need = tgt - hot;
        if (need > maxAmount) need = maxAmount;

        // A5: Withdraw from legacy + multi-adapters (deduplicated) until filled or exhausted
        pulled = _withdrawFromAdapters(need);

        if (pulled > 0) {
            emit BufferRefilled(pulled, 0);
        }
    }

    /* ===== A5: Multi-Adapter Management ===== */

    /// @notice Get list of warm adapters
    function getWarmAdapters() external view returns (address[] memory) {
        return _warmAdapters;
    }

    /// @notice Add a warm adapter to the list (onlyOwner)
    function addWarmAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();

        // Verify adapter implements IWarmAdapter interface
        try IWarmAdapter(adapter).totalAssets() returns (
            uint256
        ) {
        // Success - adapter is valid
        }
        catch {
            revert WarmAdapterZero();
        }

        _warmAdapters.push(adapter);
        emit WarmAdapterAdded(adapter, _warmAdapters.length - 1);
    }

    /// @notice Remove a warm adapter from the list (onlyOwner)
    function removeWarmAdapter(uint256 index) external onlyOwner {
        if (index >= _warmAdapters.length) revert("BufferManager: index out of bounds");

        address removed = _warmAdapters[index];

        // Swap with last element and pop (gas efficient removal)
        _warmAdapters[index] = _warmAdapters[_warmAdapters.length - 1];
        _warmAdapters.pop();

        emit WarmAdapterRemoved(removed, index);
    }

    // --- Internal helpers ---

    /// @dev True if `a` is present in `_warmAdapters` (first `len` entries).
    function _isInWarmAdapters(address a, uint256 len) internal view returns (bool) {
        for (uint256 i = 0; i < len;) {
            if (_warmAdapters[i] == a) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Withdraws up to `amount` from warm adapters, stopping once filled. Each
    ///      adapter is retried (via `_withdrawFromAdapterWithRetry`) while it keeps
    ///      making progress on the residual, instead of moving on after a single
    ///      partial fill — an adapter that rations funds per call (e.g. a per-call
    ///      cap or rate limit) is given repeated chances to deliver the full request
    ///      before the loop advances to the next adapter. Legacy `cfg.warmAdapter` is
    ///      skipped if it is also present in `_warmAdapters` — otherwise it would be
    ///      retried a second time (via a different code path) for the same underlying
    ///      adapter, since the default config seeds `_warmAdapters[0]` with the legacy
    ///      adapter (see `_setConfig`). Mirrors the dedup already used by
    ///      `warmBalance()` and `_updateWarmNavCache()`.
    /// @dev Does not revert on adapter failure or under-delivery — a failing adapter
    ///      shouldn't block trying the next one. Callers that need a delivery
    ///      guarantee check the returned total themselves (see `refill()`'s slippage
    ///      check); a failure is still surfaced via `WarmWithdrawAdapterFailed`
    ///      rather than silently swallowed.
    function _withdrawFromAdapters(uint256 amount) internal returns (uint256 totalReceived) {
        uint256 remaining = amount;
        uint256 len = _warmAdapters.length;
        address legacyWarm = _cfg.warmAdapter;

        if (legacyWarm != address(0) && remaining > 0 && !_isInWarmAdapters(legacyWarm, len)) {
            uint256 received = _withdrawFromAdapterWithRetry(legacyWarm, remaining);
            totalReceived += received;
            remaining = received >= remaining ? 0 : remaining - received;
        }

        for (uint256 i = 0; i < len && remaining > 0;) {
            uint256 received = _withdrawFromAdapterWithRetry(_warmAdapters[i], remaining);
            totalReceived += received;
            remaining = received >= remaining ? 0 : remaining - received;
            unchecked {
                ++i;
            }
        }
    }

    event WarmWithdrawAdapterFailed(address indexed adapter, uint256 requested);

    /// @dev Repeatedly calls `adapter.withdraw()` for the residual while it keeps
    ///      making progress (received > 0), up to MAX_ADAPTER_WITHDRAW_ATTEMPTS.
    ///      Stops early (no revert) on a zero-progress call or a revert — either
    ///      means this adapter is exhausted/unavailable for now, so the caller moves
    ///      on to the next adapter rather than getting stuck. A revert is still
    ///      surfaced via `WarmWithdrawAdapterFailed` for visibility.
    function _withdrawFromAdapterWithRetry(address adapter, uint256 remaining)
        internal
        returns (uint256 received)
    {
        for (uint8 attempt; attempt < MAX_ADAPTER_WITHDRAW_ATTEMPTS && remaining > 0;) {
            try IWarmAdapter(adapter).withdraw(remaining, core) returns (uint256 got) {
                if (got == 0) break;
                received += got;
                remaining = got >= remaining ? 0 : remaining - got;
            } catch {
                emit WarmWithdrawAdapterFailed(adapter, remaining);
                break;
            }
            unchecked {
                ++attempt;
            }
        }
    }

    /// @dev Attempts to deploy `amount` into `_warmAdapters` in order, stopping at the
    ///      first adapter that succeeds. Generalizes the old len==1/len==2-only paths
    ///      to an arbitrary adapter count. Returns true if any adapter accepted the
    ///      deposit; funds stay hot if every adapter reverts.
    function _deployToAdapters(uint256 amount) internal returns (bool deployed) {
        uint256 len = _warmAdapters.length;
        address primary = _warmAdapters[0];

        for (uint256 i = 0; i < len;) {
            address adapter = _warmAdapters[i];
            try IWarmAdapter(adapter).deposit(amount) returns (uint256 received) {
                if (i == 0) {
                    emit WarmDeploySuccess(adapter, amount);
                } else {
                    emit WarmDeployFallbackUsed(primary, adapter, amount);
                }
                emit BufferDeployed(amount, received);
                return true;
            } catch {
                // Try next adapter
            }
            unchecked {
                ++i;
            }
        }

        emit WarmDeployAllFailed(amount);
        return false;
    }

    function _clearWarmAdapters() internal {
        while (_warmAdapters.length > 0) {
            uint256 idx = _warmAdapters.length - 1;
            address removed = _warmAdapters[idx];
            _warmAdapters.pop();
            emit WarmAdapterRemoved(removed, idx);
        }
    }
}
