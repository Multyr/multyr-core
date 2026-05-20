// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyScorer } from "../../interfaces/IStrategyScorer.sol";
import { IStrategyScorerV10 } from "../../interfaces/IStrategyScorerV10.sol";
import { IExecutionMemory } from "../../interfaces/IExecutionMemory.sol";
import { IStrategyHealthRegistry } from "../../interfaces/IStrategyHealthRegistry.sol";

/// @title StrategyScorer — Dynamic inter-strategy scoring and allocation
/// @notice Replicates the adapter-level scoring model from StrategyScoringModule
///         at the router/inter-strategy level. Uses keeper-poked metrics since
///         IStrategy does not expose APY/risk/liquidity natively.
/// @dev    Standalone contract (NOT delegatecall). Called by StrategyRouter as view.
///         Score formula: score = wAPY*apyNorm + wLiq*liq + wRisk*(10000-risk) + wStability*stability + wIncentive*decayedIncentive
contract StrategyScorer is IStrategyScorerV10 {

    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    uint16 public constant DEFAULT_RISK_BPS = 7000;
    uint16 public constant DEFAULT_STABILITY_BPS = 7000;
    uint16 public constant DEFAULT_LIQ_BPS = 5000;
    uint16 public constant MISSING_RISK_BPS = 4500;
    uint16 public constant MISSING_STABILITY_BPS = 3500;
    uint16 public constant MISSING_LIQ_BPS = 2500;
    uint16 public constant STALE_RISK_FLOOR_BPS = 4000;
    uint16 public constant STALE_STABILITY_FLOOR_BPS = 3000;
    uint16 public constant STALE_LIQ_FLOOR_BPS = 2000;
    uint8 public constant MAX_STRATEGIES = 10;

    // ═══════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════

    error NotOwner();
    error NotKeeper();
    error WeightsSumInvalid(uint256 sum);
    error TooManyStrategies(uint256 count);
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event ScoringWeightsUpdated(uint16 wAPY, uint16 wLiq, uint16 wRisk, uint16 wStability, uint16 wIncentive);
    event StrategyAPYPoked(address indexed strategy, uint16 apyBps);
    event StrategyLiquidityPoked(address indexed strategy, uint16 liquidityBps);
    event StrategyStabilityPoked(address indexed strategy, uint16 stabilityBps);
    event StrategyRiskSet(address indexed strategy, uint16 riskBps);
    event StrategyIncentiveSet(address indexed strategy, uint16 incentiveBps);
    event RebalanceMinMoveBpsSet(uint16 bps);
    event MaxStrategyExposureBpsSet(uint16 bps);
    event RelativeCapBpsSet(address indexed strategy, uint16 bps);
    event KeeperSet(address indexed keeper);
    event HealthRegistrySet(address indexed registry);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event ScoreFallbackUsed();
    event StrategyExternalTvlPoked(address indexed strategy, uint256 externalTvl);
    event RiskStalenessSecondsSet(uint32 seconds_);
    event LiquidityStalenessSecondsSet(uint32 seconds_);
    event StabilityStalenessSecondsSet(uint32 seconds_);
    event StrategyExternalTvlStalenessSecondsSet(uint32 seconds_);
    event AllocationConfidenceParamsSet(
        uint16 minConfidenceForAllocationBps,
        uint16 minAllocationMultiplierBps,
        uint16 lowConfidenceCoreAllocationMultiplierBps,
        uint16 tacticalAllocationMultiplierBps
    );
    event ExecutionMemorySet(address indexed executionMemory);
    event ExecutionQualityParamsSet(uint16 executionPenaltyFloorBps, uint16 executionSlipPenaltyScalarBps);

    // ═══════════════════════════════════════════════════════════════════
    // STATE — Scoring Weights
    // ═══════════════════════════════════════════════════════════════════

    uint16 public wAPY = 4000;          // 40%
    uint16 public wLiq = 1500;          // 15%
    uint16 public wRisk = 2500;         // 25%
    uint16 public wStability = 1000;    // 10%
    uint16 public wIncentive = 1000;    // 10%

    // ═══════════════════════════════════════════════════════════════════
    // STATE — Per-Strategy Cached Metrics
    // ═══════════════════════════════════════════════════════════════════

    mapping(address => uint16) public strategyAPYBps;
    mapping(address => uint16) public strategyRiskBps;
    mapping(address => uint16) public strategyLiquidityBps;
    mapping(address => uint16) public strategyStabilityBps;
    mapping(address => uint16) public strategyIncentiveBps;
    mapping(address => uint64) public incentiveSetTs;
    mapping(address => uint64) public lastRiskUpdateTs;
    mapping(address => uint64) public lastLiquidityUpdateTs;
    mapping(address => uint64) public lastStabilityUpdateTs;
    mapping(address => uint256) public cachedStrategyExternalTvl;
    mapping(address => uint64) public lastStrategyExternalTvlTs;

    // ═══════════════════════════════════════════════════════════════════
    // STATE — Config
    // ═══════════════════════════════════════════════════════════════════

    uint32 public incentiveDecayHalfLife = 604800; // 1 week
    uint16 public rebalanceMinMoveBps = 200;       // 2% min drift to trigger rebalance
    uint16 public maxStrategyExposureBps = 5000;   // 50% max any single strategy
    mapping(address => uint16) public relativeCapBps; // per-strategy relative cap vs external TVL
    uint32 public riskStalenessSeconds = 3 days;
    uint32 public liquidityStalenessSeconds = 2 days;
    uint32 public stabilityStalenessSeconds = 2 days;
    uint32 public strategyExternalTvlStalenessSeconds = 1 days;
    uint16 public minConfidenceForAllocationBps = 1500;
    uint16 public minAllocationMultiplierBps = 2500;
    uint16 public lowConfidenceCoreAllocationMultiplierBps = 3000;
    uint16 public tacticalAllocationMultiplierBps = 8500;
    uint16 public executionPenaltyFloorBps = 2500;
    uint16 public executionSlipPenaltyScalarBps = 20;

    // ═══════════════════════════════════════════════════════════════════
    // STATE — Access
    // ═══════════════════════════════════════════════════════════════════

    address public owner;
    address public keeper;
    address public executionMemory;
    IStrategyHealthRegistry public healthRegistry;

    // ═══════════════════════════════════════════════════════════════════
    // STATE — V10 EXTENSIONS (portfolio-grade allocation engine)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Time-aware EMA state per strategy (Correction #9).
    struct EmaState {
        uint64 lastUpdateTs;
        uint32 emaApyBps;
        uint32 apyVolatilityBps;
    }
    mapping(address => EmaState) internal _emaState;
    uint32 public maxEmaGap = 7 days;

    /// @notice Risk-adjustment penalties (bps subtracted from EMA APY).
    mapping(address => uint16) public volatilityPenaltyBps;
    mapping(address => uint16) public illiquidityPenaltyBps;
    mapping(address => uint16) public operationalRiskBps;

    /// @notice Confidence with source validity + staleness decay (Correction #8).
    mapping(address => uint16) public confidenceBps;
    mapping(address => uint64) public lastConfidenceTs;
    mapping(address => bool)   public confidenceSourceValid;
    uint16 public defaultConfidenceBps     = 5000;  // conservative
    uint16 public staleConfidenceFloorBps  = 2500;  // floor after 2x staleness
    uint32 public confidenceStalenessSeconds = 86400;

    /// @notice Capital bucket classification (0 = CORE, 1 = TACTICAL). Governance-only (Correction #7).
    mapping(address => uint8) internal _strategyBucket;

    // V10 events
    event EmaUpdated(address indexed strategy, uint32 emaApyBps, uint32 apyVolatilityBps, uint8 path);
    event ConfidencePoked(address indexed strategy, uint16 confidenceBps);
    event ConfidenceSourceValiditySet(address indexed strategy, bool valid);
    event RiskPenaltiesSet(address indexed strategy, uint16 volatilityPenaltyBps, uint16 illiquidityPenaltyBps, uint16 operationalRiskBps);
    event StrategyBucketSet(address indexed strategy, uint8 bucket);
    event DefaultConfidenceBpsSet(uint16 bps);
    event StaleConfidenceFloorBpsSet(uint16 bps);
    event ConfidenceStalenessSecondsSet(uint32 s);
    event MaxEmaGapSet(uint32 s);
    event StrategyMetricsPoked(address indexed strategy, uint16 spotApy, uint16 emaApy, uint16 volatility, uint16 confidence);

    // ═══════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyKeeper() { if (msg.sender != keeper && msg.sender != owner) revert NotKeeper(); _; }

    // ═══════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    constructor(address owner_, address keeper_, address healthRegistry_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (keeper_ == address(0)) revert ZeroAddress();
        owner = owner_;
        keeper = keeper_;
        if (healthRegistry_ != address(0)) {
            healthRegistry = IStrategyHealthRegistry(healthRegistry_);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW — Scoring
    // ═══════════════════════════════════════════════════════════════════

    /// @inheritdoc IStrategyScorer
    function computeScores(address[] calldata strategies)
        external view override returns (StrategyScore[] memory scores)
    {
        uint256 n = strategies.length;
        if (n > MAX_STRATEGIES) revert TooManyStrategies(n);
        if (n == 0) return new StrategyScore[](0);

        scores = new StrategyScore[](n);

        // Pass 1: collect APYs, find max for normalization
        uint16 maxAPY = 0;
        for (uint256 i = 0; i < n;) {
            uint16 apy = this.riskAdjustedAPY(strategies[i]);
            if (apy > maxAPY) maxAPY = apy;
            scores[i].strategy = strategies[i];
            scores[i].apyBps = apy;
            unchecked { ++i; }
        }

        // Pass 2: compute weighted scores
        uint16 wA = wAPY;
        uint16 wL = wLiq;
        uint16 wR = wRisk;
        uint16 wS = wStability;
        uint16 wI = wIncentive;

        for (uint256 i = 0; i < n;) {
            address s = strategies[i];

            // APY normalized relative to max (0-10000)
            uint256 apyNorm = maxAPY > 0 ? (uint256(scores[i].apyBps) * 1e4) / maxAPY : 0;

            uint16 confidence = this.effectiveConfidence(s);
            uint256 liq = _effectiveLiquidityScore(s, confidence);
            uint256 risk = _effectiveRiskScore(s, confidence);
            uint256 stability = _effectiveStabilityScore(s, confidence);

            // Incentive with decay
            uint256 incentive = (_decayedIncentive(s) * confidence) / 1e4;

            uint256 score = uint256(wA) * apyNorm
                + uint256(wL) * liq
                + uint256(wR) * risk
                + uint256(wS) * stability
                + uint256(wI) * incentive;
            score = (score * _executionQualityMultiplierBps(s)) / 1e4;

            scores[i].score = score;
            scores[i].riskBps = uint16(risk);
            scores[i].liquidityBps = uint16(liq);
            scores[i].stabilityBps = uint16(stability);
            scores[i].incentiveBps = uint16(incentive);

            unchecked { ++i; }
        }

        // Normalize scores to sum = 10000
        _normalizeScores(scores);
    }

    /// @inheritdoc IStrategyScorer
    function computeAllocations(address[] calldata strategies, uint256 tvl)
        external view override returns (uint256[] memory allocations)
    {
        uint256 n = strategies.length;
        if (n > MAX_STRATEGIES) revert TooManyStrategies(n);
        allocations = new uint256[](n);
        if (n == 0 || tvl == 0) return allocations;

        StrategyScore[] memory scores = this.computeScores(strategies);

        uint256 totalScore = 0;
        for (uint256 i = 0; i < n;) {
            totalScore += scores[i].score;
            unchecked { ++i; }
        }
        if (totalScore == 0) return allocations;

        uint256 maxExp = (uint256(maxStrategyExposureBps) * tvl) / 1e4;
        uint256[] memory effectiveScores = new uint256[](n);
        uint256 adjustedTotalScore = 0;
        for (uint256 i = 0; i < n;) {
            uint256 adjusted = (scores[i].score * _allocationMultiplierBps(strategies[i])) / 1e4;
            effectiveScores[i] = adjusted;
            adjustedTotalScore += adjusted;
            unchecked { ++i; }
        }
        if (adjustedTotalScore == 0) return allocations;

        for (uint256 i = 0; i < n;) {
            uint256 raw = (effectiveScores[i] * tvl) / adjustedTotalScore;

            // Absolute cap
            if (raw > maxExp) raw = maxExp;

            // Relative cap (vs strategy external TVL)
            uint16 relCap = relativeCapBps[strategies[i]];
            if (relCap > 0) {
                (uint256 extTVL, bool capDataOk) = _resolveStrategyExternalTvl(strategies[i]);
                if (!capDataOk) {
                    raw = 0;
                } else {
                    uint256 relMax = (uint256(relCap) * extTVL) / 1e4;
                    if (raw > relMax) raw = relMax;
                }
            }

            allocations[i] = raw;
            unchecked { ++i; }
        }
    }

    /// @inheritdoc IStrategyScorer
    function shouldRebalance(
        address[] calldata strategies,
        uint256[] calldata currentAllocs,
        uint256 tvl
    ) external view override returns (bool) {
        if (strategies.length != currentAllocs.length) return false;
        if (strategies.length < 2 || tvl == 0) return false;

        uint256[] memory targets = this.computeAllocations(strategies, tvl);

        uint256 totalDrift = 0;
        for (uint256 i = 0; i < strategies.length;) {
            uint256 c = currentAllocs[i];
            uint256 t = targets[i];
            totalDrift += c > t ? c - t : t - c;
            unchecked { ++i; }
        }

        // Proportional drift in bps
        uint256 driftBps = (totalDrift * 10000) / tvl;
        return driftBps >= rebalanceMinMoveBps;
    }

    /// @inheritdoc IStrategyScorer
    function isEligible(address strategy) external view override returns (bool) {
        if (address(healthRegistry) == address(0)) return true;
        try healthRegistry.isHealthyForDeposit(strategy) returns (bool ok) {
            return ok;
        } catch {
            return false; // FAIL-CLOSED
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // KEEPER — Poke Functions
    // ═══════════════════════════════════════════════════════════════════

    function pokeStrategyAPY(address strategy, uint16 apyBps) external onlyKeeper {
        strategyAPYBps[strategy] = apyBps;
        _updateEma(strategy, apyBps);
        emit StrategyAPYPoked(strategy, apyBps);
    }

    function pokeStrategyLiquidity(address strategy, uint16 liquidityBps) external onlyKeeper {
        strategyLiquidityBps[strategy] = liquidityBps;
        lastLiquidityUpdateTs[strategy] = uint64(block.timestamp);
        emit StrategyLiquidityPoked(strategy, liquidityBps);
    }

    function pokeStrategyStability(address strategy, uint16 stabilityBps) external onlyKeeper {
        strategyStabilityBps[strategy] = stabilityBps;
        lastStabilityUpdateTs[strategy] = uint64(block.timestamp);
        emit StrategyStabilityPoked(strategy, stabilityBps);
    }

    function pokeStrategyExternalTvl(address strategy, uint256 externalTvl) external onlyKeeper {
        cachedStrategyExternalTvl[strategy] = externalTvl;
        lastStrategyExternalTvlTs[strategy] = uint64(block.timestamp);
        emit StrategyExternalTvlPoked(strategy, externalTvl);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GOVERNANCE — Config
    // ═══════════════════════════════════════════════════════════════════

    function setStrategyRisk(address strategy, uint16 riskBps) external onlyOwner {
        strategyRiskBps[strategy] = riskBps;
        lastRiskUpdateTs[strategy] = uint64(block.timestamp);
        emit StrategyRiskSet(strategy, riskBps);
    }

    function setStrategyIncentive(address strategy, uint16 incentiveBps) external onlyOwner {
        strategyIncentiveBps[strategy] = incentiveBps;
        incentiveSetTs[strategy] = uint64(block.timestamp);
        emit StrategyIncentiveSet(strategy, incentiveBps);
    }

    function setScoringWeights(
        uint16 _wAPY, uint16 _wLiq, uint16 _wRisk, uint16 _wStability, uint16 _wIncentive
    ) external onlyOwner {
        uint256 sum = uint256(_wAPY) + _wLiq + _wRisk + _wStability + _wIncentive;
        if (sum != 10000) revert WeightsSumInvalid(sum);
        wAPY = _wAPY;
        wLiq = _wLiq;
        wRisk = _wRisk;
        wStability = _wStability;
        wIncentive = _wIncentive;
        emit ScoringWeightsUpdated(_wAPY, _wLiq, _wRisk, _wStability, _wIncentive);
    }

    function setRebalanceMinMoveBps(uint16 bps) external onlyOwner {
        rebalanceMinMoveBps = bps;
        emit RebalanceMinMoveBpsSet(bps);
    }

    function setMaxStrategyExposureBps(uint16 bps) external onlyOwner {
        require(bps <= 10000, "max 100%");
        maxStrategyExposureBps = bps;
        emit MaxStrategyExposureBpsSet(bps);
    }

    function setRelativeCapBps(address strategy, uint16 bps) external onlyOwner {
        relativeCapBps[strategy] = bps;
        emit RelativeCapBpsSet(strategy, bps);
    }

    function setRiskStalenessSeconds(uint32 seconds_) external onlyOwner {
        riskStalenessSeconds = seconds_;
        emit RiskStalenessSecondsSet(seconds_);
    }

    function setLiquidityStalenessSeconds(uint32 seconds_) external onlyOwner {
        liquidityStalenessSeconds = seconds_;
        emit LiquidityStalenessSecondsSet(seconds_);
    }

    function setStabilityStalenessSeconds(uint32 seconds_) external onlyOwner {
        stabilityStalenessSeconds = seconds_;
        emit StabilityStalenessSecondsSet(seconds_);
    }

    function setStrategyExternalTvlStalenessSeconds(uint32 seconds_) external onlyOwner {
        strategyExternalTvlStalenessSeconds = seconds_;
        emit StrategyExternalTvlStalenessSecondsSet(seconds_);
    }

    function setAllocationConfidenceParams(
        uint16 minConfidenceBps_,
        uint16 minAllocMultBps_,
        uint16 lowConfidenceCoreMultBps_,
        uint16 tacticalAllocMultBps_
    ) external onlyOwner {
        require(minConfidenceBps_ <= 10000, "conf>10000");
        require(minAllocMultBps_ <= 10000, "mult>10000");
        require(lowConfidenceCoreMultBps_ <= 10000, "core>10000");
        require(tacticalAllocMultBps_ <= 10000, "tact>10000");
        minConfidenceForAllocationBps = minConfidenceBps_;
        minAllocationMultiplierBps = minAllocMultBps_;
        lowConfidenceCoreAllocationMultiplierBps = lowConfidenceCoreMultBps_;
        tacticalAllocationMultiplierBps = tacticalAllocMultBps_;
        emit AllocationConfidenceParamsSet(
            minConfidenceBps_,
            minAllocMultBps_,
            lowConfidenceCoreMultBps_,
            tacticalAllocMultBps_
        );
    }

    function setExecutionMemory(address executionMemory_) external onlyOwner {
        executionMemory = executionMemory_;
        emit ExecutionMemorySet(executionMemory_);
    }

    function setExecutionQualityParams(
        uint16 executionPenaltyFloorBps_,
        uint16 executionSlipPenaltyScalarBps_
    ) external onlyOwner {
        require(executionPenaltyFloorBps_ <= 10000, "floor>10000");
        executionPenaltyFloorBps = executionPenaltyFloorBps_;
        executionSlipPenaltyScalarBps = executionSlipPenaltyScalarBps_;
        emit ExecutionQualityParamsSet(executionPenaltyFloorBps_, executionSlipPenaltyScalarBps_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        require(keeper_ != address(0), "zero");
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setHealthRegistry(address registry) external onlyOwner {
        require(registry != address(0), "zero");
        healthRegistry = IStrategyHealthRegistry(registry);
        emit HealthRegistrySet(registry);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _normalizeScores(StrategyScore[] memory scores) internal pure {
        uint256 len = scores.length;
        if (len == 0) return;

        uint256 sum = 0;
        for (uint256 i = 0; i < len;) {
            sum += scores[i].score;
            unchecked { ++i; }
        }

        if (sum < 1) {
            uint256 qualitySum = 0;
            for (uint256 i = 0; i < len;) {
                qualitySum += uint256(scores[i].riskBps)
                    + uint256(scores[i].liquidityBps)
                    + uint256(scores[i].stabilityBps);
                unchecked { ++i; }
            }
            if (qualitySum == 0) {
                uint256 equalShare = 1e4 / len;
                for (uint256 i = 0; i < len;) {
                    scores[i].score = equalShare;
                    unchecked { ++i; }
                }
                return;
            }
            for (uint256 i = 0; i < len;) {
                uint256 quality = uint256(scores[i].riskBps)
                    + uint256(scores[i].liquidityBps)
                    + uint256(scores[i].stabilityBps);
                scores[i].score = (quality * 1e4) / qualitySum;
                unchecked { ++i; }
            }
            return;
        }

        for (uint256 i = 0; i < len;) {
            scores[i].score = (scores[i].score * 1e4) / sum;
            unchecked { ++i; }
        }
    }

    function _decayedIncentive(address strategy) internal view returns (uint256) {
        uint16 inc = strategyIncentiveBps[strategy];
        if (inc == 0) return 0;
        uint64 setTs = incentiveSetTs[strategy];
        if (setTs == 0) return 0;
        if (block.timestamp <= setTs) return inc;

        uint256 elapsed = block.timestamp - setTs;
        uint256 k = elapsed / incentiveDecayHalfLife;
        if (k >= 16) return 0; // fully decayed
        return uint256(inc) >> k;
    }

    function _effectiveLiquidityScore(address strategy, uint16 confidence) internal view returns (uint16) {
        uint256 liq = strategyLiquidityBps[strategy];
        uint64 ts = lastLiquidityUpdateTs[strategy];
        if (ts == 0) {
            liq = MISSING_LIQ_BPS;
        } else if (
            liquidityStalenessSeconds > 0
                && block.timestamp - ts > liquidityStalenessSeconds
        ) {
            liq = liq / 2;
            if (liq < STALE_LIQ_FLOOR_BPS) liq = STALE_LIQ_FLOOR_BPS;
        } else if (liq == 0) {
            liq = DEFAULT_LIQ_BPS;
        }
        liq = (liq * confidence) / 1e4;
        return uint16(liq);
    }

    function _effectiveRiskScore(address strategy, uint16 confidence) internal view returns (uint16) {
        uint256 riskScore = strategyRiskBps[strategy];
        uint64 ts = lastRiskUpdateTs[strategy];
        uint256 risk = riskScore > 0 ? (10000 - riskScore) : DEFAULT_RISK_BPS;
        if (ts == 0 && riskScore == 0) {
            risk = MISSING_RISK_BPS;
        } else if (
            ts > 0
                && riskStalenessSeconds > 0
                && block.timestamp - ts > riskStalenessSeconds
        ) {
            risk = risk / 2;
            if (risk < STALE_RISK_FLOOR_BPS) risk = STALE_RISK_FLOOR_BPS;
        }
        risk = (risk * confidence) / 1e4;
        return uint16(risk);
    }

    function _effectiveStabilityScore(address strategy, uint16 confidence) internal view returns (uint16) {
        uint256 stability = strategyStabilityBps[strategy];
        uint64 ts = lastStabilityUpdateTs[strategy];
        if (ts == 0) {
            stability = MISSING_STABILITY_BPS;
        } else if (
            stabilityStalenessSeconds > 0
                && block.timestamp - ts > stabilityStalenessSeconds
        ) {
            stability = stability / 2;
            if (stability < STALE_STABILITY_FLOOR_BPS) stability = STALE_STABILITY_FLOOR_BPS;
        } else if (stability == 0) {
            stability = DEFAULT_STABILITY_BPS;
        }
        stability = (stability * confidence) / 1e4;
        return uint16(stability);
    }

    function _allocationMultiplierBps(address strategy) internal view returns (uint16) {
        uint16 confidence = this.effectiveConfidence(strategy);
        uint8 bucket = _strategyBucket[strategy];

        if (confidence < minConfidenceForAllocationBps) {
            if (bucket == 1) return 0;
            return lowConfidenceCoreAllocationMultiplierBps;
        }

        uint256 confRange = 10000 - uint256(minConfidenceForAllocationBps);
        uint256 confDelta = uint256(confidence) - uint256(minConfidenceForAllocationBps);
        uint256 confMult = uint256(minAllocationMultiplierBps);
        if (confRange > 0) {
            confMult += (confDelta * (10000 - uint256(minAllocationMultiplierBps))) / confRange;
        }

        if (bucket == 1) {
            confMult = (confMult * uint256(tacticalAllocationMultiplierBps)) / 1e4;
        }
        confMult = (confMult * uint256(_executionQualityMultiplierBps(strategy))) / 1e4;
        return uint16(confMult);
    }

    function _executionQualityMultiplierBps(address strategy) internal view returns (uint16) {
        if (executionMemory == address(0)) return 10000;

        uint16 penalty = IExecutionMemory(executionMemory).getPenalty(strategy);
        (, uint16 slipBps) = IExecutionMemory(executionMemory).getExpectedCost(strategy);

        uint256 slipPenalty = uint256(slipBps) * uint256(executionSlipPenaltyScalarBps);
        if (slipPenalty > 3000) slipPenalty = 3000;

        uint256 mult = penalty + slipPenalty >= 10000 ? 0 : 10000 - penalty - slipPenalty;
        if (mult < executionPenaltyFloorBps) mult = executionPenaltyFloorBps;
        return uint16(mult);
    }

    function _resolveStrategyExternalTvl(address strategy) internal view returns (uint256 extTvl, bool ok) {
        try IStrategyLike(strategy).totalAssets() returns (uint256 liveExtTvl) {
            return (liveExtTvl, true);
        } catch {
            uint64 ts = lastStrategyExternalTvlTs[strategy];
            if (
                ts > 0
                    && (
                        strategyExternalTvlStalenessSeconds == 0
                            || block.timestamp - ts <= strategyExternalTvlStalenessSeconds
                    )
            ) {
                return (cachedStrategyExternalTvl[strategy], true);
            }
            return (0, false);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // V10 — Time-aware EMA (Correction #9)
    // ═══════════════════════════════════════════════════════════════════

    /// @dev Bucketed alpha by dt since last update. Handles first-observation and long-gap reseed.
    function _updateEma(address strategy, uint16 spotApyBps) internal {
        EmaState storage s = _emaState[strategy];

        // First observation: seed directly.
        if (s.lastUpdateTs == 0) {
            s.emaApyBps = uint32(spotApyBps);
            s.apyVolatilityBps = 0;
            s.lastUpdateTs = uint64(block.timestamp);
            emit EmaUpdated(strategy, s.emaApyBps, s.apyVolatilityBps, 0);
            return;
        }

        uint256 dt = block.timestamp - s.lastUpdateTs;
        uint32 prevEma = s.emaApyBps;

        // Long-gap reseed.
        if (dt > maxEmaGap) {
            s.emaApyBps = uint32(spotApyBps);
            s.apyVolatilityBps = 0;
            s.lastUpdateTs = uint64(block.timestamp);
            emit EmaUpdated(strategy, s.emaApyBps, s.apyVolatilityBps, 1);
            return;
        }

        // Bucketed alpha.
        uint16 alphaBps;
        if (dt < 6 hours)       alphaBps = 1000;
        else if (dt < 1 days)   alphaBps = 2500;
        else if (dt < 3 days)   alphaBps = 4000;
        else                    alphaBps = 6000;

        uint256 newEma = (uint256(alphaBps) * spotApyBps + (10000 - alphaBps) * prevEma) / 10000;

        // Volatility: EMA of |spot - prevEma|, using prev EMA BEFORE mutation (exactly once).
        uint256 err = spotApyBps > prevEma ? spotApyBps - prevEma : uint256(prevEma) - spotApyBps;
        uint256 newVol = (2000 * err + 8000 * s.apyVolatilityBps) / 10000;

        s.emaApyBps = uint32(newEma);
        s.apyVolatilityBps = uint32(newVol);
        s.lastUpdateTs = uint64(block.timestamp);
        emit EmaUpdated(strategy, s.emaApyBps, s.apyVolatilityBps, 2);
    }

    /// @inheritdoc IStrategyScorerV10
    function emaState(address strategy) external view override returns (
        uint64 lastUpdateTs, uint32 emaApyBps, uint32 apyVolatilityBps
    ) {
        EmaState memory s = _emaState[strategy];
        return (s.lastUpdateTs, s.emaApyBps, s.apyVolatilityBps);
    }

    /// @inheritdoc IStrategyScorerV10
    function riskAdjustedAPY(address strategy) external view override returns (uint16) {
        EmaState memory s = _emaState[strategy];
        int256 adj = int256(uint256(s.emaApyBps))
                   - int256(uint256(volatilityPenaltyBps[strategy]))
                   - int256(uint256(illiquidityPenaltyBps[strategy]))
                   - int256(uint256(operationalRiskBps[strategy]));
        if (adj <= 0) return 0;
        if (adj > int256(uint256(type(uint16).max))) return type(uint16).max;
        return uint16(uint256(adj));
    }

    /// @inheritdoc IStrategyScorerV10
    /// @dev Source-validity check (Correction #8): missing source is NOT full confidence.
    ///      Default = defaultConfidenceBps (conservative, e.g. 5000).
    ///      Stale (age > stalenessSeconds): raw/2. Very stale (age > 2x): clamp to floor.
    function effectiveConfidence(address strategy) external view override returns (uint16) {
        if (!confidenceSourceValid[strategy]) return defaultConfidenceBps;
        uint16 raw = confidenceBps[strategy];
        uint256 age = block.timestamp - lastConfidenceTs[strategy];
        if (age > 2 * uint256(confidenceStalenessSeconds)) return staleConfidenceFloorBps;
        if (age > confidenceStalenessSeconds) return raw / 2;
        return raw;
    }

    /// @inheritdoc IStrategyScorerV10
    function strategyBucket(address strategy) external view override returns (uint8) {
        return _strategyBucket[strategy];
    }

    /// @inheritdoc IStrategyScorerV10
    /// @dev Single-call batch poke. Keeper efficiency: update APY+EMA, liquidity, stability, confidence together.
    function pokeStrategyMetrics(
        address strategy,
        uint16 spotApyBps,
        uint16 liqBps,
        uint16 stabBps,
        uint16 confBps
    ) external override onlyKeeper {
        strategyAPYBps[strategy] = spotApyBps;
        _updateEma(strategy, spotApyBps);

        if (liqBps > 0) {
            strategyLiquidityBps[strategy] = liqBps;
            lastLiquidityUpdateTs[strategy] = uint64(block.timestamp);
            emit StrategyLiquidityPoked(strategy, liqBps);
        }
        if (stabBps > 0) {
            strategyStabilityBps[strategy] = stabBps;
            lastStabilityUpdateTs[strategy] = uint64(block.timestamp);
            emit StrategyStabilityPoked(strategy, stabBps);
        }

        confidenceBps[strategy] = confBps;
        lastConfidenceTs[strategy] = uint64(block.timestamp);
        confidenceSourceValid[strategy] = true;

        EmaState memory s = _emaState[strategy];
        emit StrategyMetricsPoked(strategy, spotApyBps, uint16(s.emaApyBps), uint16(s.apyVolatilityBps), confBps);
    }

    // ═══════════════════════════════════════════════════════════════════
    // V10 — Governance setters
    // ═══════════════════════════════════════════════════════════════════

    function setRiskPenalties(
        address strategy,
        uint16 volBps,
        uint16 illiqBps,
        uint16 opRiskBps
    ) external onlyOwner {
        volatilityPenaltyBps[strategy] = volBps;
        illiquidityPenaltyBps[strategy] = illiqBps;
        operationalRiskBps[strategy] = opRiskBps;
        emit RiskPenaltiesSet(strategy, volBps, illiqBps, opRiskBps);
    }

    function setConfidenceSourceValid(address strategy, bool valid) external onlyOwner {
        confidenceSourceValid[strategy] = valid;
        emit ConfidenceSourceValiditySet(strategy, valid);
    }

    function setStrategyBucket(address strategy, uint8 bucket) external onlyOwner {
        require(bucket <= 1, "bucket:invalid"); // 0 CORE, 1 TACTICAL
        _strategyBucket[strategy] = bucket;
        emit StrategyBucketSet(strategy, bucket);
    }

    function setDefaultConfidenceBps(uint16 bps) external onlyOwner {
        require(bps <= 10000, "bps>10000");
        defaultConfidenceBps = bps;
        emit DefaultConfidenceBpsSet(bps);
    }

    function setStaleConfidenceFloorBps(uint16 bps) external onlyOwner {
        require(bps <= 10000, "bps>10000");
        staleConfidenceFloorBps = bps;
        emit StaleConfidenceFloorBpsSet(bps);
    }

    function setConfidenceStalenessSeconds(uint32 s) external onlyOwner {
        confidenceStalenessSeconds = s;
        emit ConfidenceStalenessSecondsSet(s);
    }

    function setMaxEmaGap(uint32 s) external onlyOwner {
        maxEmaGap = s;
        emit MaxEmaGapSet(s);
    }
}

// Minimal interface for totalAssets query
interface IStrategyLike {
    function totalAssets() external view returns (uint256);
}
