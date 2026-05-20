// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IStrategyRouter, IStrategy } from "../../interfaces/IStrategyRouter.sol";
import { IParamsProvider } from "../../interfaces/IParamsProvider.sol";
import { IPriceOracleMiddleware } from "../../interfaces/IPriceOracleMiddleware.sol";
import { IStrategyHealthRegistry } from "../../interfaces/IStrategyHealthRegistry.sol";
import { IStrategyScorer } from "../../interfaces/IStrategyScorer.sol";
import { IBufferManager } from "../../interfaces/IBufferManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ICoreVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function bufferManager() external view returns (IBufferManager);
}

contract StrategyRouter is IStrategyRouter, ReentrancyGuard {
    // ---------------- access ----------------
    address public override core; // unico chiamante autorizzato alle funzioni mutative operative
    address public owner; // admin/guardian
    modifier onlyOwner() {
        require(msg.sender == owner, "not-owner");
        _;
    }
    modifier onlyCore() {
        require(msg.sender == core, "not-core");
        _;
    }

    // ---------------- state ----------------
    IntakeMode public override intakeMode = IntakeMode.PRIORITY;
    uint16 public override lossCapBps = 50; // 0.50% di tolleranza perdita su redeem batch

    StrategyInfo[] private _strats; // elenco
    mapping(address => uint256) private _idx; // strat => index+1 (0 = non registrata)

    // --- Guardrails Integration (Phase 2) ---
    IParamsProvider public params; // unified params interface
    uint64 public lastBatchTimestamp; // timestamp of last batch operation

    // --- Multi-Oracle Validation (Security Enhancement) ---
    address public secondaryOracle; // optional secondary oracle for price validation
    uint16 public maxOracleDeviationBps; // max deviation between oracles (e.g., 200 = 2%)

    // --- Strategy Health Tracking (A1: Audit Fix) ---
    IStrategyHealthRegistry public healthRegistry; // centralized health tracking
    mapping(address => uint16) public lossCapPerStrategy; // per-strategy loss cap in bps (A2: Audit Fix)
    mapping(address => uint16) public maxStrategyBps; // B1: per-strategy allocation cap in bps (% of NAV)

    // --- Dynamic Scoring (Inter-Strategy) ---
    address public scorer; // IStrategyScorer for SCORED mode

    // --- Gas-adaptive batch sizing (C1: Audit Fix) ---
    uint256 public gasPerStrategyWithdraw = 100000; // Estimated gas per strategy withdraw (default: 100k)

    // --- PR-EO: Execute-only guardrails ---
    uint8 public constant MAX_DEPOSIT_LEGS = 12; // Max number of strategies per deposit batch

    /// @dev P9: Gas cap per strategy totalAssets() call — now configurable via GlobalConfig
    function _stratTaGas() internal view returns (uint256) {
        if (address(params) == address(0)) return 1_000_000;
        uint256 g = params.stratTaGas(core);
        return g > 0 ? g : 1_000_000;
    }

    // ---------------- events ----------------
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event CoreSet(address indexed core);
    event StrategyRegistered(address indexed strat, uint16 priority, uint16 weightBps);
    event StrategyToggled(address indexed strat, bool enabled);
    event IntakeModeSet(IntakeMode mode);
    event WeightsSet(address[] strats, uint16[] weights);
    event LossCapSet(uint16 capBps);
    event ParamsProviderSet(address indexed params);
    event SecondaryOracleSet(address indexed oracle);
    event MaxOracleDeviationSet(uint16 deviationBps);
    event HealthRegistrySet(address indexed registry);
    event LossCapPerStrategySet(address indexed strategy, uint16 capBps);
    event MaxStrategyBpsSet(address indexed strategy, uint16 maxBps); // B1
    event GasPerStrategyWithdrawUpdated(uint256 gasAmount); // C1
    event ScorerSet(address indexed scorer);
    event NoEligibleStrategyDetected();

    // Harvest telemetry events (Pendle-style)
    event StrategyHarvested(address indexed strat, int256 pnl, uint256 realized);
    event StrategyHarvestFailed(address indexed strat, bytes reason);
    event HarvestBatchSummary(uint256 visited, int256 aggPnl, uint256 aggRealized);

    // Best-effort batch telemetry events (PR4: Audit-Grade)
    event StrategyDepositSuccess(address indexed strat, uint256 amount);
    event StrategyDepositSkipped(address indexed strat, uint256 amount, bytes reason);
    event DepositBatchSummary(uint256 attempted, uint256 succeeded, uint256 totalDeposited);
    event StrategyRedeemSuccess(address indexed strat, uint256 requested, uint256 received);
    event StrategyRedeemSkipped(address indexed strat, uint256 amount, bytes reason);
    event RedeemBatchSummary(uint256 attempted, uint256 succeeded, uint256 totalReceived);

    // ---------------- errors ----------------
    error CooldownNotMet(uint256 timeSinceLastBatch, uint256 minCooldown);
    error TooManyActions(uint256 requested, uint256 max);
    error AdapterNotAllowed(address adapter);
    error NavDeltaExceeded(uint256 navDeltaBps, uint256 maxDeltaBps);
    error OracleDataStale(address oracle, uint256 age, uint256 maxAge);
    error OracleNotConfigured(address asset); // Hard fail if oracle not registered for asset
    error OraclePriceMismatch(uint256 price1, uint256 price2, uint256 deviationBps);
    error OracleCallFailed(address oracle, bytes revertData); // Wraps raw revert from oracle.getQuote
    error StrategyDepositFailed(address strat, bytes revertData); // Wraps raw revert from strategy.deposit (strict path only)
    error LossCapExceeded(address strat, uint256 expected, uint256 received, uint256 lossBps); // PR4: Critical
    error AggregatedLossCapExceeded(uint256 requested, uint256 received, uint256 lossBps); // PR4: Critical

    // PR-EO errors defined in IStrategyRouter interface

    // ---------------- ctor ----------------
    constructor(address owner_, address core_, address params_) {
        require(owner_ != address(0), "owner=0");
        require(core_ != address(0), "core=0");
        require(params_ != address(0), "params=0");
        owner = owner_;
        core = core_;
        params = IParamsProvider(params_);
        emit OwnerChanged(address(0), owner_);
        emit CoreSet(core_);
        emit ParamsProviderSet(params_);
    }

    // ---------------- admin ----------------
    function setCore(address core_) external override onlyOwner {
        require(core_ != address(0), "core=0");
        core = core_;
        emit CoreSet(core_);
    }

    function setParamsProvider(address params_) external onlyOwner {
        require(params_ != address(0), "params=0");
        params = IParamsProvider(params_);
        emit ParamsProviderSet(params_);
    }

    /// @notice Set secondary oracle for price validation
    /// @dev Zero address disables secondary oracle validation. Adds redundancy to prevent price manipulation.
    function setSecondaryOracle(address oracle_) external onlyOwner {
        // Note: Zero address allowed to disable secondary oracle
        secondaryOracle = oracle_;
        emit SecondaryOracleSet(oracle_);
    }

    /// @notice Set maximum allowed deviation between oracles
    /// @param deviationBps Max deviation in basis points (e.g., 200 = 2%)
    function setMaxOracleDeviation(uint16 deviationBps) external onlyOwner {
        require(deviationBps <= 1000, "max 10%"); // Prevent misconfiguration
        maxOracleDeviationBps = deviationBps;
        emit MaxOracleDeviationSet(deviationBps);
    }

    /// @notice Set strategy health registry (A1: Audit Fix)
    /// @param registry Address of StrategyHealthRegistry contract
    function setHealthRegistry(address registry) external onlyOwner {
        require(registry != address(0), "registry=0");
        healthRegistry = IStrategyHealthRegistry(registry);
        emit HealthRegistrySet(registry);
    }

    /// @notice Set per-strategy loss cap (A2: Audit Fix)
    /// @param strategy Strategy address
    /// @param capBps Loss cap in basis points (e.g., 50 = 0.5%)
    function setLossCapPerStrategy(address strategy, uint16 capBps) external onlyOwner {
        require(capBps <= 500, "cap>5%"); // Max 5% per-strategy loss
        lossCapPerStrategy[strategy] = capBps;
        emit LossCapPerStrategySet(strategy, capBps);
    }

    /// @notice Set per-strategy allocation cap (B1: Audit Fix)
    /// @param strategy Strategy address
    /// @param maxBps Max allocation as % of NAV in bps (e.g., 3000 = 30%)
    function setMaxStrategyBps(address strategy, uint16 maxBps) external onlyOwner {
        require(maxBps <= 10000, "max 100%"); // Cannot exceed 100% of NAV
        maxStrategyBps[strategy] = maxBps;
        emit MaxStrategyBpsSet(strategy, maxBps);
    }

    /// @notice Set gas estimate per strategy withdraw (C1: Audit Fix)
    /// @param gasAmount Estimated gas per withdraw (e.g., 100000)
    function setGasPerStrategyWithdraw(uint256 gasAmount) external onlyOwner {
        require(gasAmount >= 50000 && gasAmount <= 500000, "gas out of range");
        gasPerStrategyWithdraw = gasAmount;
        emit GasPerStrategyWithdrawUpdated(gasAmount);
    }

    /// @notice Set the strategy scorer for SCORED intake mode
    function setScorer(address scorer_) external onlyOwner {
        scorer = scorer_;
        emit ScorerSet(scorer_);
    }

    function register(address strat, uint16 priority, uint16 weightBps)
        external
        override
        onlyOwner
    {
        require(strat != address(0), "strat=0");
        require(_idx[strat] == 0, "exists");
        // Enforce: strategy.asset() must equal core.asset() (USDC native on Arbitrum)
        (bool okCore, bytes memory dataCore) = core.staticcall(abi.encodeWithSignature("asset()"));
        require(okCore && dataCore.length == 32, "core.asset()");
        address coreAsset = abi.decode(dataCore, (address));
        (bool okStrat, bytes memory dataStrat) =
            strat.staticcall(abi.encodeWithSignature("asset()"));
        require(okStrat && dataStrat.length == 32, "strat.asset()");
        address stratAsset = abi.decode(dataStrat, (address));
        require(stratAsset == coreAsset, "asset-mismatch");
        _strats.push(
            StrategyInfo({ strat: strat, enabled: true, priority: priority, weightBps: weightBps })
        );
        _idx[strat] = _strats.length; // index+1
        emit StrategyRegistered(strat, priority, weightBps);
    }

    function toggle(address strat, bool enabled) external override onlyOwner {
        uint256 i = _requireIndex(strat);
        _strats[i].enabled = enabled;
        emit StrategyToggled(strat, enabled);
    }

    function setIntakeMode(IntakeMode m) external override onlyOwner {
        intakeMode = m;
        emit IntakeModeSet(m);
    }

    function setWeights(address[] calldata strats, uint16[] calldata weightsBps)
        external
        override
        onlyOwner
    {
        uint256 len = strats.length;
        require(len == weightsBps.length && len > 0, "args");
        uint256 sum;
        for (uint256 k = 0; k < len; k++) {
            uint256 i = _requireIndex(strats[k]);
            _strats[i].weightBps = weightsBps[k];
            sum += weightsBps[k];
        }
        require(sum == 1e4, "sum!=100%");
        emit WeightsSet(strats, weightsBps);
    }

    function setLossCapBps(uint16 capBps) external override onlyOwner {
        require(capBps <= 500, "cap>5%"); // guard-rail
        lossCapBps = capBps;
        emit LossCapSet(capBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    // ---------------- views ----------------
    function list() external view override returns (StrategyInfo[] memory) {
        return _strats;
    }

    /// @notice Check if a strategy is registered and enabled
    /// @param strat Strategy address
    /// @return True if strategy is registered and enabled
    function isStrategyEnabled(address strat) external view override returns (bool) {
        uint256 idx = _idx[strat];
        if (idx == 0) return false; // Not registered
        return _strats[idx - 1].enabled;
    }

    /// @notice Aggregate totalAssets across all enabled strategies. Never reverts.
    /// @dev Uses low-level staticcall + data.length guard (same pattern as
    ///      UsdcLendingStrategy._safeTotalAssets). Iterates _strats storage directly
    ///      (no memory copy via list()). Skips disabled strategies and any
    ///      strategy whose totalAssets() reverts or returns malformed data.
    function totalStrategyAssetsSafe() external view override returns (uint256 sum) {
        uint256 len = _strats.length;
        for (uint256 i = 0; i < len;) {
            StrategyInfo storage s = _strats[i];
            if (s.enabled) {
                (bool ok, bytes memory data) = s.strat
                .staticcall{
                    gas: _stratTaGas()
                }(abi.encodeWithSelector(IStrategy.totalAssets.selector));
                if (ok && data.length >= 32) {
                    sum += abi.decode(data, (uint256));
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Safe view: returns strategy totalAssets or 0 if call fails.
    ///      Used by planRedeem to exclude failed strategies silently.
    function _safeTotalAssetsView(address strat) internal view returns (uint256) {
        (bool ok, bytes memory data) = strat.staticcall{gas: _stratTaGas()}(
            abi.encodeWithSelector(IStrategy.totalAssets.selector)
        );
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0; // excluded: reverted/OOG/malformed
    }

    // ---------------- planning ----------------

    /// @notice Calculate deposit allocation across strategies (DEPRECATED)
    /// @dev DEPRECATED: Planning moved off-chain for PR-EO execute-only pattern.
    ///      Use script/planner/PlanDeposit.s.sol for production keeper flows.
    ///      This function is kept as view-only for debugging and reference.
    /// @param amount Amount to allocate
    /// @return plan Allocation array (for reference/debug only - do NOT use in production)
    function planDeposit(uint256 amount) public view override returns (Allocation[] memory plan) {
        if (amount == 0) return new Allocation[](0);
        // Cache array length for gas optimization
        uint256 stratsLen = _strats.length;
        // count eligible strategies (enabled + healthy) and find maxPriority
        uint256 n = 0;
        uint16 maxPriority = 0;
        for (uint256 i = 0; i < stratsLen; i++) {
            bool eligible = _strats[i].enabled;
            // Health filter: DEGRADED/BROKEN excluded from ALL modes
            if (eligible && address(healthRegistry) != address(0)) {
                try healthRegistry.isHealthyForDeposit(_strats[i].strat) returns (bool ok) {
                    eligible = ok;
                } catch { eligible = false; } // FAIL-CLOSED
            }
            if (eligible) {
                n++;
                if (_strats[i].priority > maxPriority) {
                    maxPriority = _strats[i].priority;
                }
            }
        }
        if (n == 0) return new Allocation[](0);

        plan = new Allocation[](n);
        if (intakeMode == IntakeMode.PRIORITY) {
            // ordina implicitamente per priority crescente e riempi
            uint256 remaining = amount;
            uint256 k = 0;
            // Iterate only up to maxPriority, not 65535
            for (uint256 p = 0; remaining > 0 && p <= maxPriority; p++) {
                for (uint256 i = 0; i < stratsLen && remaining > 0; i++) {
                    StrategyInfo memory s = _strats[i];
                    if (!s.enabled || s.priority != p || !_isHealthy(s.strat)) continue;
                    uint256 push = remaining;
                    plan[k++] = Allocation({
                        strat: s.strat, amount: push, fundsAlreadyTransferred: false
                    });
                    remaining = 0;
                }
            }
            if (k < n) {
                // ridimensiona array
                assembly { mstore(plan, k) }
            }
        } else if (intakeMode == IntakeMode.WEIGHTED) {
            uint256 sumW;
            for (uint256 i = 0; i < stratsLen; i++) {
                if (_strats[i].enabled && _isHealthy(_strats[i].strat)) {
                    sumW += _strats[i].weightBps;
                }
            }
            require(sumW == 1e4, "bad-weights");
            uint256 k = 0;
            uint256 acc = 0;
            for (uint256 i = 0; i < stratsLen; i++) {
                StrategyInfo memory s = _strats[i];
                if (!s.enabled || !_isHealthy(s.strat)) continue;
                uint256 part = (amount * s.weightBps) / 1e4;
                acc += part;
                plan[k++] =
                    Allocation({ strat: s.strat, amount: part, fundsAlreadyTransferred: false });
            }
            // assegna eventuali resti al primo
            if (k > 0 && acc < amount) plan[0].amount += (amount - acc);
            if (k < n) assembly { mstore(plan, k) }
        } else if (intakeMode == IntakeMode.SCORED) {
            require(scorer != address(0), "no-scorer");
            // Build eligible strategy list
            address[] memory eligible = new address[](n);
            uint256 ek = 0;
            for (uint256 i = 0; i < stratsLen; i++) {
                if (_strats[i].enabled && _isHealthy(_strats[i].strat)) {
                    eligible[ek++] = _strats[i].strat;
                }
            }
            assembly { mstore(eligible, ek) }
            if (ek == 0) {
                // NoEligibleStrategyDetected event emitted at execution time, not in view
                return new Allocation[](0);
            }
            if (ek == 1) {
                // Single eligible -> passthrough 100%
                plan = new Allocation[](1);
                plan[0] = Allocation(eligible[0], amount, false);
                return plan;
            }
            // 2+ eligible -> dynamic scoring
            uint256[] memory allocs = IStrategyScorer(scorer).computeAllocations(eligible, amount);
            plan = new Allocation[](ek);
            uint256 acc = 0;
            for (uint256 i = 0; i < ek; i++) {
                plan[i] = Allocation(eligible[i], allocs[i], false);
                acc += allocs[i];
            }
            if (acc < amount && ek > 0) plan[0].amount += (amount - acc); // dust
        } else {
            // NONE -> no automatic allocation
            return new Allocation[](0);
        }
    }

    // ---------------- Guardrail Modifiers (Phase 2) ----------------

    /// @notice Check minimum cooldown between batch operations
    modifier checkCooldown() {
        if (lastBatchTimestamp > 0) {
            uint256 elapsed = block.timestamp - lastBatchTimestamp;
            uint256 minCooldown = params.minRebalanceCooldown();
            if (elapsed < minCooldown) {
                revert CooldownNotMet(elapsed, minCooldown);
            }
        }
        _;
        lastBatchTimestamp = uint64(block.timestamp);
    }

    /// @notice Check batch size doesn't exceed limit
    modifier checkBatchSize(uint256 count) {
        uint256 max = params.maxActionsPerBatch();
        if (count > max) {
            revert TooManyActions(count, max);
        }
        _;
    }

    /// @notice Check all adapters in batch are allowlisted
    modifier checkAdapterAllowlist(address[] memory adapters) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (!params.isAdapterAllowed(adapters[i])) {
                revert AdapterNotAllowed(adapters[i]);
            }
        }
        _;
    }

    /// @notice Check NAV delta is within acceptable range
    modifier checkNavDelta(uint256 navBefore, uint256 navAfter) {
        _;
        uint256 deltaBps = _calculateNavDeltaBps(navBefore, navAfter);
        uint256 maxDelta = params.maxNavDeltaBps();
        if (deltaBps > maxDelta) {
            revert NavDeltaExceeded(deltaBps, maxDelta);
        }
    }

    /// @notice Check oracle data freshness with independent timestamp validation
    /// @dev Validates both the oracle's fresh flag AND independently checks timestamp age
    ///      This prevents a compromised oracle from lying about freshness
    ///      Uses oracleConfigFor() for asset-specific oracle lookup with staleness config
    modifier checkOracleFreshness() {
        address asset = ICoreVault(core).asset(); // Get actual vault asset (e.g., USDC)
        // Use oracleConfigFor for asset+vault specific oracle lookup with staleness
        (address oracleAddr, uint256 maxStale) = params.oracleConfigFor(asset, core);

        // SECURITY: Hard fail if oracle is not configured - never proceed without price validation
        if (oracleAddr == address(0)) {
            revert OracleNotConfigured(asset);
        }

        // Safe getQuote: wraps internal revert in OracleCallFailed (no 0x)
        IPriceOracleMiddleware.Quote memory quote = _safeGetQuote(oracleAddr, asset);

        // SECURITY: Triple-check oracle data validity
        // 1. Check oracle's self-reported fresh flag
        if (!quote.fresh) {
            uint256 ageOnStale = block.timestamp - quote.lastUpdate;
            revert OracleDataStale(oracleAddr, ageOnStale, maxStale);
        }

        // 2. Independently validate timestamp is not in the future
        if (quote.lastUpdate > block.timestamp) {
            revert OracleDataStale(oracleAddr, type(uint256).max, maxStale);
        }

        // 3. Independently validate timestamp age (don't trust fresh flag alone)
        uint256 age = block.timestamp - quote.lastUpdate;
        if (age > maxStale) {
            revert OracleDataStale(oracleAddr, age, maxStale);
        }

        // 4. Validate price is non-zero (sanity check)
        if (quote.price == 0) {
            revert OracleDataStale(oracleAddr, age, maxStale);
        }

        // 5. MULTI-ORACLE VALIDATION: Cross-check with secondary oracle if configured
        if (secondaryOracle != address(0) && maxOracleDeviationBps > 0) {
            _validateSecondaryOracle(asset, quote.price, maxStale);
        }
        _;
    }

    /// @notice Validate price against secondary oracle
    /// @dev Prevents accepting manipulated prices by requiring consensus
    /// @param asset The asset to validate price for
    /// @param primaryPrice The price from the primary oracle
    /// @param maxStale The maximum staleness from oracleConfigFor (per-asset/vault config)
    function _validateSecondaryOracle(address asset, uint256 primaryPrice, uint256 maxStale)
        internal
        view
    {
        // Safe getQuote for secondary: graceful degradation on revert or ABI mismatch
        IPriceOracleMiddleware.Quote memory secondaryQuote;
        {
            (bool ok, bytes memory data) =
                secondaryOracle.staticcall(abi.encodeWithSignature("getQuote(address)", asset));
            if (!ok || data.length != 128) return; // Secondary unavailable or ABI mismatch
            secondaryQuote = abi.decode(data, (IPriceOracleMiddleware.Quote));
        }

        // Check secondary oracle freshness using per-asset/vault staleness config
        if (!secondaryQuote.fresh) return; // Don't revert if secondary unavailable
        if (block.timestamp - secondaryQuote.lastUpdate > maxStale) return;
        if (secondaryQuote.price == 0) return;

        // Calculate deviation between oracles
        uint256 price1 = primaryPrice;
        uint256 price2 = secondaryQuote.price;
        uint256 deviation;

        if (price1 >= price2) {
            deviation = ((price1 - price2) * 10000) / price1;
        } else {
            deviation = ((price2 - price1) * 10000) / price2;
        }

        // Revert if deviation exceeds threshold
        if (deviation > maxOracleDeviationBps) {
            revert OraclePriceMismatch(price1, price2, deviation);
        }
    }

    /// @dev Safe wrapper for oracle.getQuote(asset). Never produces 0x revert.
    ///      If getQuote reverts (feed internal failure, OOG) or returns malformed data,
    ///      wraps in OracleCallFailed with the original revert/response data.
    ///      Quote = {uint256 price, uint8 decimals, uint48 lastUpdate, bool fresh} = 4 ABI words = 128 bytes.
    function _safeGetQuote(address oracleAddr, address asset)
        internal
        view
        returns (IPriceOracleMiddleware.Quote memory)
    {
        (bool ok, bytes memory data) =
            oracleAddr.staticcall(abi.encodeWithSignature("getQuote(address)", asset));
        if (!ok) revert OracleCallFailed(oracleAddr, data);
        if (data.length != 128) revert OracleCallFailed(oracleAddr, data);
        return abi.decode(data, (IPriceOracleMiddleware.Quote));
    }

    /// @dev Non-reverting strategy deposit wrapper for best-effort batch.
    ///      Eliminates 0x revert from ABI return-data mismatch (void vs uint256).
    ///      Returns (true, received, "") on success, (false, 0, revertData) on failure.
    ///      Void return (0 bytes) is backward-compatible: received = amount.
    function _tryCallStrategyDeposit(address strat, uint256 amount)
        internal
        returns (bool ok, uint256 received, bytes memory reason)
    {
        (bool success, bytes memory data) =
            strat.call(abi.encodeWithSignature("deposit(uint256)", amount));
        if (!success) return (false, 0, data);

        // Void return (0 bytes): backward-compatible — received = amount
        if (data.length == 0) return (true, amount, "");
        // Standard ABI return (32+ bytes): decode uint256 received
        if (data.length >= 32) return (true, abi.decode(data, (uint256)), "");
        // Malformed return (1-31 bytes): treat as failure
        return (false, 0, data);
    }

    /// @dev Reverting strategy deposit wrapper for strict paths.
    ///      NOT used in executeDepositBatch (which is best-effort).
    function _callStrategyDeposit(address strat, uint256 amount)
        internal
        returns (uint256 received)
    {
        (bool ok, uint256 recv, bytes memory reason) = _tryCallStrategyDeposit(strat, amount);
        if (!ok) revert StrategyDepositFailed(strat, reason);
        return recv;
    }

    /// @dev Calculate NAV delta in basis points
    function _calculateNavDeltaBps(uint256 navBefore, uint256 navAfter)
        internal
        pure
        returns (uint256)
    {
        if (navBefore == 0) return 0;
        if (navAfter >= navBefore) {
            // NAV increased
            return ((navAfter - navBefore) * 10000) / navBefore;
        } else {
            // NAV decreased
            return ((navBefore - navAfter) * 10000) / navBefore;
        }
    }

    /// @dev Get current NAV from core (totalAssets)
    function _getCoreNav() internal view returns (uint256) {
        (bool ok, bytes memory data) = core.staticcall(abi.encodeWithSignature("totalAssets()"));
        require(ok && data.length == 32, "totalAssets()");
        return abi.decode(data, (uint256));
    }

    /// @dev Extract adapter addresses from Allocation array
    function _extractAdapters(Allocation[] calldata plan) internal pure returns (address[] memory) {
        uint256 len = plan.length;
        address[] memory adapters = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            adapters[i] = plan[i].strat;
        }
        return adapters;
    }

    /// @dev Extract adapter addresses from Pull array
    function _extractAdaptersFromPulls(Pull[] calldata plan)
        internal
        pure
        returns (address[] memory)
    {
        uint256 len = plan.length;
        address[] memory adapters = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            adapters[i] = plan[i].strat;
        }
        return adapters;
    }

    function executeDepositBatch(Allocation[] calldata plan)
        external
        override
        nonReentrant
        onlyCore
        checkCooldown
        checkAdapterAllowlist(_extractAdapters(plan))
        checkOracleFreshness
    {
        // ═══════════════════════════════════════════════════════════════════════════════
        // PHASE 1: FAIL-FAST VALIDATION (all checks before any state changes)
        // ═══════════════════════════════════════════════════════════════════════════════

        // 1.1 Plan length check
        uint256 planLen = plan.length;
        if (planLen > MAX_DEPOSIT_LEGS) {
            revert PlanTooLong(planLen, MAX_DEPOSIT_LEGS);
        }

        // 1.2 NAV snapshot (single source of truth for cap checks)
        uint256 navBefore = _getCoreNav();

        // 1.3-1.5: Validate plan + compute available surplus (accounting for pre-transferred funds)
        uint256 planSum = 0;
        uint256 alreadyTransferredSum = 0;
        for (uint256 i = 0; i < planLen; i++) {
            if (!_isRegistered(plan[i].strat)) revert StrategyUnregistered(plan[i].strat);
            if (!_isEnabled(plan[i].strat)) revert StrategyDisabled(plan[i].strat);
            if (plan[i].amount == 0) revert InvalidPlanAmount();
            planSum += plan[i].amount;
            if (plan[i].fundsAlreadyTransferred) alreadyTransferredSum += plan[i].amount;
        }

        // Available surplus: reconstruct pre-transfer hot balance to avoid double-subtraction
        uint256 available = _getAvailableSurplusWithOffset(alreadyTransferredSum);
        if (planSum > available) revert InvalidPlanSum(planSum, available);

        // ═══════════════════════════════════════════════════════════════════════════════
        // PHASE 2: BEST-EFFORT EXECUTION (for non-critical failures)
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256 attempted = 0;
        uint256 succeeded = 0;
        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < planLen; i++) {
            attempted++;

            // A1: Check strategy health before deposit (skip if unhealthy - non-critical)
            if (address(healthRegistry) != address(0)) {
                if (!healthRegistry.isHealthyForDeposit(plan[i].strat)) {
                    emit StrategyDepositSkipped(plan[i].strat, plan[i].amount, "strategy-unhealthy");
                    continue;
                }
            }

            // B1: Check per-strategy allocation cap (skip if would exceed cap - non-critical)
            // NOTE: If fundsAlreadyTransferred is true, CoreVault has already transferred
            // plan[i].amount to the strategy address. In this case, strategy.totalAssets()
            // already includes the pending amount in its idle balance, so we must NOT add
            // plan[i].amount again (that would double-count and trigger false cap violations).
            // FIX: Use navBefore (snapshot), not _getCoreNav() inside loop
            if (maxStrategyBps[plan[i].strat] > 0) {
                try IStrategy(plan[i].strat).totalAssets() returns (uint256 strategyAssetsBefore) {
                    uint256 strategyAssetsAfter = plan[i].fundsAlreadyTransferred
                        ? strategyAssetsBefore
                        : strategyAssetsBefore + plan[i].amount;
                    uint256 allocBps = (strategyAssetsAfter * 10000) / navBefore; // FIX: use navBefore

                    if (allocBps > maxStrategyBps[plan[i].strat]) {
                        emit StrategyDepositSkipped(plan[i].strat, plan[i].amount, "cap-exceeded");
                        continue;
                    }
                } catch (bytes memory reason) {
                    emit StrategyDepositSkipped(plan[i].strat, plan[i].amount, reason);
                    continue;
                }
            }

            // BEST-EFFORT: Low-level deposit — immune to ABI return-data mismatch (void vs uint256)
            // Requisito: il Core ha già trasferito 'amount' alla strategy address
            (bool depositOk, uint256 received, bytes memory depositReason) =
                _tryCallStrategyDeposit(plan[i].strat, plan[i].amount);
            if (depositOk) {
                emit StrategyDepositSuccess(plan[i].strat, plan[i].amount);
                succeeded++;
                totalDeposited += received; // CTO: sum actual received, not planned amount

                // A1: Update cached NAV after successful operation (non-critical)
                if (address(healthRegistry) != address(0)) {
                    try IStrategy(plan[i].strat).totalAssets() returns (uint256 nav) {
                        healthRegistry.updateLastKnownNAV(plan[i].strat, nav);
                    } catch { }
                }
            } else {
                emit StrategyDepositSkipped(plan[i].strat, plan[i].amount, depositReason);
                // Continue - don't revert batch for non-critical failure
            }
        }

        emit DepositBatchSummary(attempted, succeeded, totalDeposited);

        // CRITICAL CHECK: NAV delta (still revert if violated)
        uint256 navAfter = _getCoreNav();
        uint256 deltaBps = _calculateNavDeltaBps(navBefore, navAfter);
        uint256 maxDelta = params.maxNavDeltaBps();
        if (deltaBps > maxDelta) {
            revert NavDeltaExceeded(deltaBps, maxDelta);
        }
    }

    function planRedeem(uint256 required) external view override returns (Pull[] memory plan) {
        if (required == 0) return new Pull[](0);
        // Cache array length for gas optimization
        uint256 stratsLen = _strats.length;
        uint256 n = 0;
        uint16 maxPriority = 0;
        for (uint256 i = 0; i < stratsLen; i++) {
            if (_strats[i].enabled) {
                n++;
                if (_strats[i].priority > maxPriority) {
                    maxPriority = _strats[i].priority;
                }
            }
        }
        if (n == 0) return new Pull[](0);

        // C1: Gas-adaptive batch sizing - limit strategies based on available gas
        uint256 maxStrategies = n;
        if (gasPerStrategyWithdraw > 0 && gasleft() > 0) {
            uint256 gasReserve = 200000; // Reserve gas for post-processing
            uint256 availableGas = gasleft() > gasReserve ? gasleft() - gasReserve : 0;
            uint256 gasBasedMax = availableGas / gasPerStrategyWithdraw;
            if (gasBasedMax < maxStrategies) {
                maxStrategies = gasBasedMax;
            }
        }
        if (maxStrategies == 0) maxStrategies = 1; // At least try one strategy

        plan = new Pull[](n);

        if (intakeMode == IntakeMode.WEIGHTED) {
            // Proportional withdrawal — resilient to strategy totalAssets() failure
            uint256 totalAUM = 0;
            for (uint256 i = 0; i < stratsLen; i++) {
                if (!_strats[i].enabled) continue;
                uint256 sa = _safeTotalAssetsView(_strats[i].strat);
                totalAUM += sa;
            }
            if (totalAUM == 0) return new Pull[](0);

            uint256 k = 0;
            uint256 acc = 0;
            for (uint256 i = 0; i < stratsLen && k < maxStrategies; i++) {
                if (!_strats[i].enabled) continue;
                uint256 ta = _safeTotalAssetsView(_strats[i].strat);
                if (ta == 0) continue;
                uint256 part = (required * ta) / totalAUM;
                if (part > ta) part = ta; // cap at available
                acc += part;
                plan[k++] = Pull({ strat: _strats[i].strat, amount: part });
            }
            // assign remaining dust to first strategy if needed
            if (k > 0 && acc < required) {
                uint256 dust = required - acc;
                plan[0].amount += dust;
            }
            if (k < n) assembly { mstore(plan, k) }
        } else {
            // Priority-based withdrawal (drain highest priority first)
            uint256 need = required;
            uint256 k = 0;
            // Iterate only up to maxPriority, not 65535
            for (uint256 p = 0; need > 0 && p <= maxPriority && k < maxStrategies; p++) {
                for (uint256 i = 0; i < stratsLen && need > 0 && k < maxStrategies; i++) {
                    StrategyInfo memory s = _strats[i];
                    if (!s.enabled || s.priority != p || !_isHealthy(s.strat)) continue;
                    uint256 ta = _safeTotalAssetsView(s.strat);
                    if (ta == 0) continue;
                    uint256 take = ta >= need ? need : ta;
                    plan[k++] = Pull({ strat: s.strat, amount: take });
                    need -= take;
                }
            }
            if (k < n) assembly { mstore(plan, k) }
        }
    }

    function executeRedeemBatch(Pull[] calldata plan)
        external
        override
        nonReentrant
        onlyCore
        checkCooldown
        checkBatchSize(plan.length)
        checkAdapterAllowlist(_extractAdaptersFromPulls(plan))
        checkOracleFreshness
        returns (uint256 got, uint256 loss)
    {
        uint256 navBefore = _getCoreNav();

        address to = core;
        uint256 balanceBefore = _balance(to);

        uint256 redeemPlanLen = plan.length;
        uint256 attempted = 0;
        uint256 succeeded = 0;
        uint256 totalRequested = 0;

        for (uint256 i = 0; i < redeemPlanLen; i++) {
            if (plan[i].amount == 0) continue;
            attempted++;
            totalRequested += plan[i].amount;

            uint256 balanceBeforeWithdraw = _balance(to);

            // A2: Track per-strategy NAV before withdrawal (for loss cap check)
            uint256 stratNavBefore = 0;
            if (lossCapPerStrategy[plan[i].strat] > 0 || address(healthRegistry) != address(0)) {
                try IStrategy(plan[i].strat).totalAssets() returns (uint256 nav) {
                    stratNavBefore = nav;
                } catch {
                    // If NAV query fails, use cached value from healthRegistry
                    if (address(healthRegistry) != address(0)) {
                        IStrategyHealthRegistry.StrategyHealth memory health =
                            healthRegistry.getStrategyHealth(plan[i].strat);
                        stratNavBefore = health.lastKnownNAV;
                    }
                }
            }

            // BEST-EFFORT: Try withdraw
            try IStrategy(plan[i].strat).withdraw(plan[i].amount, to) {
                uint256 received = _balance(to) - balanceBeforeWithdraw;

                // CRITICAL CHECK: Per-strategy loss cap (revert if violated)
                if (lossCapPerStrategy[plan[i].strat] > 0 && plan[i].amount > 0) {
                    uint256 minExpected =
                        (plan[i].amount * (10000 - lossCapPerStrategy[plan[i].strat])) / 10000;
                    if (received < minExpected) {
                        uint256 lossBps = ((plan[i].amount - received) * 10000) / plan[i].amount;
                        revert LossCapExceeded(plan[i].strat, plan[i].amount, received, lossBps);
                    }
                }

                emit StrategyRedeemSuccess(plan[i].strat, plan[i].amount, received);
                succeeded++;

                // A1: Update cached NAV after withdrawal (non-critical)
                if (address(healthRegistry) != address(0)) {
                    try IStrategy(plan[i].strat).totalAssets() returns (uint256 nav) {
                        healthRegistry.updateLastKnownNAV(plan[i].strat, nav);
                    } catch { }
                }
            } catch (bytes memory reason) {
                emit StrategyRedeemSkipped(plan[i].strat, plan[i].amount, reason);
                // Continue for non-critical failures
            }
        }

        got = _balance(to) - balanceBefore;
        emit RedeemBatchSummary(attempted, succeeded, got);

        // CRITICAL CHECK: Aggregated loss cap (revert if violated)
        if (totalRequested > got && totalRequested > 0) {
            loss = ((totalRequested - got) * 10000) / totalRequested;
            if (loss > lossCapBps) {
                revert AggregatedLossCapExceeded(totalRequested, got, loss);
            }
        }

        // CRITICAL CHECK: NAV delta (revert if violated)
        uint256 navAfter = _getCoreNav();
        uint256 deltaBps = _calculateNavDeltaBps(navBefore, navAfter);
        uint256 maxDelta = params.maxNavDeltaBps();
        if (deltaBps > maxDelta) {
            revert NavDeltaExceeded(deltaBps, maxDelta);
        }
    }

    function harvest(uint256 maxStrategies)
        external
        override
        onlyCore
        returns (uint256 visited, int256 aggPnl, uint256 aggRealized)
    {
        uint256 stratsLen = _strats.length;
        if (stratsLen == 0) return (0, 0, 0);

        // Count enabled strategies to know when to stop
        uint256 enabledCount = 0;
        uint16 maxPriority = 0;
        for (uint256 i = 0; i < stratsLen; i++) {
            if (_strats[i].enabled) {
                enabledCount++;
                if (_strats[i].priority > maxPriority) {
                    maxPriority = _strats[i].priority;
                }
            }
        }
        if (enabledCount == 0) return (0, 0, 0);

        // Determine effective max (0 means unlimited)
        uint256 effectiveMax = maxStrategies == 0 ? enabledCount : maxStrategies;
        if (effectiveMax > enabledCount) effectiveMax = enabledCount;

        uint256 count = 0;
        // Only iterate up to maxPriority + 1, not 65535
        for (uint256 p = 0; p <= maxPriority && count < effectiveMax; p++) {
            for (uint256 i = 0; i < stratsLen && count < effectiveMax; i++) {
                StrategyInfo memory s = _strats[i];
                if (!s.enabled || s.priority != p) continue;

                // Try/catch for harvest with telemetry events (Pendle-style)
                try IStrategy(s.strat).harvest() returns (int256 pnl, uint256 realized) {
                    emit StrategyHarvested(s.strat, pnl, realized);
                    aggPnl += pnl;
                    aggRealized += realized;
                } catch (bytes memory reason) {
                    emit StrategyHarvestFailed(s.strat, reason);
                    // Continue to next strategy - don't revert the entire batch
                }
                count++;
            }
        }
        visited = count;

        // Emit batch summary
        emit HarvestBatchSummary(visited, aggPnl, aggRealized);
    }

    function withdrawAllToCore(address strat) external override onlyOwner returns (uint256 got) {
        got = IStrategy(strat).withdrawAll(core);
    }

    // ---------------- helpers ----------------
    function _balance(address a) internal view returns (uint256) {
        // chiama ERC20(asset).balanceOf(a) via staticcall (eviti import OZ)
        (bool ok, bytes memory data) = core.staticcall(abi.encodeWithSignature("asset()"));
        require(ok && data.length == 32, "core.asset()");
        address token = abi.decode(data, (address));
        (ok, data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", a));
        require(ok && data.length == 32, "balanceOf");
        return abi.decode(data, (uint256));
    }

    /// @dev Check if strategy is healthy for deposits (FAIL-CLOSED)
    function _isHealthy(address strat) internal view returns (bool) {
        if (address(healthRegistry) == address(0)) return true;
        try healthRegistry.isHealthyForDeposit(strat) returns (bool ok) { return ok; }
        catch { return false; } // FAIL-CLOSED: health check failure = excluded
    }

    function _requireIndex(address strat) internal view returns (uint256 i) {
        uint256 idx1 = _idx[strat];
        require(idx1 != 0, "not-registered");
        i = idx1 - 1;
    }

    // ---------------- PR-EO: Execute-only helpers ----------------

    /// @dev Get available surplus for investment (hot - opsReserve)
    /// @return available Amount that can be safely invested without touching ops reserve
    function _getAvailableSurplus() internal view returns (uint256) {
        return _getAvailableSurplusWithOffset(0);
    }

    /// @dev Get available surplus accounting for funds already transferred out of core.
    /// @param offset Amount already transferred from core (to reconstruct pre-transfer hot balance)
    function _getAvailableSurplusWithOffset(uint256 offset) internal view returns (uint256) {
        address assetAddr = ICoreVault(core).asset();
        uint256 hot = IERC20(assetAddr).balanceOf(core) + offset;

        // Get ops reserve target from BufferManager
        try ICoreVault(core).bufferManager() returns (IBufferManager bm) {
            if (address(bm) != address(0)) {
                uint16 opsReserveBps = bm.getConfig().opsReserveTargetBps;
                if (opsReserveBps > 0) {
                    uint256 nav = ICoreVault(core).totalAssets();
                    uint256 minHot = (nav * opsReserveBps) / 1e4;
                    return hot > minHot ? hot - minHot : 0;
                }
            }
        } catch { }

        // Fallback: if no BufferManager, use full hot balance
        return hot;
    }

    /// @dev Check if strategy is registered
    function _isRegistered(address strat) internal view returns (bool) {
        return _idx[strat] != 0;
    }

    /// @dev Check if strategy is enabled (assumes registered)
    function _isEnabled(address strat) internal view returns (bool) {
        uint256 idx = _idx[strat];
        return _strats[idx - 1].enabled;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EMERGENCY REDEEM (v8) — bypasses lossCap, navDelta, cooldown, oracle checks
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Emergency redeem: withdraw from strategies without lossCap/navDelta guards
    /// @dev ONLY owner (Timelock/Safe). Used for vault drain/recovery when normal redeem
    ///      is blocked by LossCapExceeded (e.g., v6 recovery incident).
    ///      Still uses nonReentrant and emits events for audit trail.
    /// @param plan Array of (strategy, amount) pulls
    /// @return got Total assets received
    function emergencyRedeemBatch(Pull[] calldata plan)
        external
        nonReentrant
        onlyOwner
        returns (uint256 got)
    {
        address to = core;
        uint256 balanceBefore = _balance(to);

        for (uint256 i = 0; i < plan.length; i++) {
            if (plan[i].amount == 0) continue;

            try IStrategy(plan[i].strat).withdraw(plan[i].amount, to) {
                uint256 received = _balance(to) - balanceBefore - got;
                emit StrategyRedeemSuccess(plan[i].strat, plan[i].amount, received);
                got += received;
            } catch (bytes memory reason) {
                emit StrategyRedeemSkipped(plan[i].strat, plan[i].amount, reason);
            }
        }

        got = _balance(to) - balanceBefore;
        emit RedeemBatchSummary(plan.length, plan.length, got);
        // NO lossCap check, NO navDelta check — emergency path
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FORCE WITHDRAW PATH — Deterministic Exit (W2 Policy)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Force redeem for forceWithdrawAll — greedy extraction, NO LossCap.
    /// @dev Called by ERC4626Module via delegatecall (onlyCore).
    ///      Extracts liquidity greedily: iterates enabled strategies sorted by
    ///      available liquidity (desc), pulls as much as possible from each.
    ///      Skips reverting strategies without blocking the entire batch.
    ///      NO loss cap check — force exit path must never be blocked.
    /// @param amount Target USDC to extract
    /// @return got Total USDC actually received
    function forceRedeemForWithdraw(uint256 amount)
        external
        nonReentrant
        onlyCore
        returns (uint256 got)
    {
        if (amount == 0) return 0;

        address to = core;
        uint256 balanceBefore = _balance(to);
        uint256 remaining = amount;

        // Build list of enabled strategies with their available liquidity
        uint256 stratsLen = _strats.length;
        uint256 enabledCount = 0;

        // Temp arrays for greedy sort
        address[] memory addrs = new address[](stratsLen);
        uint256[] memory avail = new uint256[](stratsLen);

        for (uint256 i = 0; i < stratsLen;) {
            if (_strats[i].enabled) {
                addrs[enabledCount] = _strats[i].strat;
                // Get available assets (best-effort query)
                (bool ok, bytes memory ret) = _strats[i].strat.staticcall(
                    abi.encodeWithSignature("totalAssets()")
                );
                avail[enabledCount] = (ok && ret.length >= 32)
                    ? abi.decode(ret, (uint256))
                    : 0;
                enabledCount++;
            }
            unchecked { ++i; }
        }

        // Greedy sort: highest available first (simple insertion sort, N <= 10)
        for (uint256 i = 1; i < enabledCount; i++) {
            uint256 key = avail[i];
            address keyAddr = addrs[i];
            uint256 j = i;
            while (j > 0 && avail[j - 1] < key) {
                avail[j] = avail[j - 1];
                addrs[j] = addrs[j - 1];
                j--;
            }
            avail[j] = key;
            addrs[j] = keyAddr;
        }

        // Greedy extraction: pull from most-liquid first
        for (uint256 i = 0; i < enabledCount && remaining > 0;) {
            uint256 toPull = remaining < avail[i] ? remaining : avail[i];
            if (toPull == 0) { unchecked { ++i; } continue; }

            try IStrategy(addrs[i]).withdraw(toPull, to) {
                uint256 received = _balance(to) - balanceBefore - got;
                got += received;
                remaining = amount > got ? amount - got : 0;
                emit StrategyRedeemSuccess(addrs[i], toPull, received);
            } catch (bytes memory reason) {
                emit ForceRedeemAdapterSkipped(addrs[i], toPull, reason);
            }
            unchecked { ++i; }
        }

        emit ForceRedeemCompleted(amount, got);
        // NO lossCap check — force exit path
    }

    event ForceRedeemAdapterSkipped(address indexed strategy, uint256 requested, bytes reason);
    event ForceRedeemCompleted(uint256 requested, uint256 got);
}
