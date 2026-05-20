// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategy {
    function name() external view returns (string memory);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    // Nota: il Core trasferisce l'underlying qui PRIMA di chiamare deposit(amount)
    function deposit(uint256 amount) external returns (uint256 received);

    // La strategia invia l'underlying a `to` (di solito il Core)
    function withdraw(uint256 amount, address to) external returns (uint256 withdrawn);

    function withdrawAll(address to) external returns (uint256 withdrawn);
    function harvest() external returns (int256 pnl, uint256 realized);
    function setActive(bool a) external;
    function isActive() external view returns (bool);
}

interface IStrategyRouter {
    struct StrategyInfo {
        address strat;
        bool enabled;
        uint16 priority; // 0 = più alta; usato in modalità PRIORITY
        uint16 weightBps; // somma pesi = 1e4 in modalità WEIGHTED
    }

    enum IntakeMode {
        NONE,
        PRIORITY,
        WEIGHTED,
        SCORED      // Dynamic scoring via StrategyScorer
    }

    struct Allocation {
        address strat;
        uint256 amount;
        bool fundsAlreadyTransferred; // true = CoreVault already transferred funds to strategy
    }

    struct Pull {
        address strat;
        uint256 amount;
    }

    // ---- admin ----
    function setCore(address core_) external;
    function register(address strat, uint16 priority, uint16 weightBps) external;
    function toggle(address strat, bool enabled) external;
    function setIntakeMode(IntakeMode m) external;
    function setWeights(address[] calldata strats, uint16[] calldata weightsBps) external;
    function setLossCapBps(uint16 capBps) external;

    // ---- views ----
    function core() external view returns (address);
    function intakeMode() external view returns (IntakeMode);
    function lossCapBps() external view returns (uint16);
    function list() external view returns (StrategyInfo[] memory);
    /// @notice Check if a strategy is registered and enabled
    function isStrategyEnabled(address strat) external view returns (bool);

    /// @notice Aggregate totalAssets across all enabled strategies. Never reverts.
    function totalStrategyAssetsSafe() external view returns (uint256);

    // ---- deposit routing ----
    /// @notice calcola come ripartire `amount` tra le strategie abilitate (no trasferimenti)
    function planDeposit(uint256 amount) external view returns (Allocation[] memory plan);

    /// @notice esegue i depositi (chiama deposit sulle strategie) assumendo che il Core abbia già trasferito gli asset alle strategie previste
    function executeDepositBatch(Allocation[] calldata plan) external;

    // ---- withdraw routing ----
    /// @notice calcola un piano di rientro per coprire `required` (in underlying)
    function planRedeem(uint256 required) external view returns (Pull[] memory plan);

    /// @notice esegue i prelievi dalle strategie verso il Core (no transfer del Router)
    function executeRedeemBatch(Pull[] calldata plan) external returns (uint256 got, uint256 loss);

    /// @notice Force redeem for forceWithdrawAll — greedy extraction, NO LossCap.
    function forceRedeemForWithdraw(uint256 amount) external returns (uint256 got);

    // ---- upkeep ----
    /// @notice chiama harvest su n strategie (in ordine di priority), con limite
    function harvest(uint256 maxStrategies)
        external
        returns (uint256 visited, int256 aggPnl, uint256 aggRealized);

    // ---- emergencies ----
    function withdrawAllToCore(address strat) external returns (uint256 got);

    // ---- PR-EO: Execute-only guardrail errors ----
    error InvalidPlanSum(uint256 planSum, uint256 available);
    error StrategyUnregistered(address strat);
    error StrategyDisabled(address strat);
    error PlanTooLong(uint256 planLength, uint256 maxLegs);
    error InvalidPlanAmount();
}
