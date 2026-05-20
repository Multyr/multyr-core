// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBufferManager - Interfaccia modulo Buffer (hot/warm)
interface IBufferManager {
    /// @dev Configurazione del buffer (in basis points, 1e4 = 100%)
    struct BufferConfig {
        uint16 targetHotBps; // es. 300 = 3% NAV
        uint16 minHotBps; // es. 200 = 2% NAV
        uint16 targetWarmBps; // es. 700 = 7% NAV
        uint16 maxWarmBps; // es. 1000 = 10% NAV
        uint16 opsReserveTargetBps; // A3: target reserve for operations (100 = 1%)
        uint16 maxWarmSlippageBps; // C2: max slippage on warm withdraw (50 = 0.5%)
        address asset; // asset base (es. USDC.e)
        address warmAdapter; // DEPRECATED - use warmAdapters array via getWarmAdapters()
        uint32 twapWindowSec; // riservato estensioni
        bool paused; // kill-switch del modulo
    }

    // A5: Multi-adapter warm buffer events
    event WarmAdapterAdded(address indexed adapter, uint256 index);
    event WarmAdapterRemoved(address indexed adapter, uint256 index);

    event BufferRefilled(uint256 amount, uint256 newHotPctBps);
    event BufferDeployed(uint256 amount, uint256 newHotPctBps);
    event BufferConfigUpdated(BufferConfig cfg);
    event BufferPaused(bool paused);

    function getConfig() external view returns (BufferConfig memory);
    function hotBalance() external view returns (uint256);
    function warmBalance() external view returns (uint256);
    function totalBuffer() external view returns (uint256);

    /// @notice compute-only: quanto servirebbe muovere per centrare i target?
    /// @return needRefill amount (warm->hot)
    /// @return needDeploy amount (hot->warm)
    function plan() external view returns (uint256 needRefill, uint256 needDeploy);

    /// @notice ribilancia: se hot < minHot → refill; se hot > targetHot → deploy (richiede trasferimento Core→Adapter)
    function rebalance() external;

    /// @notice FIX B: Check if rebalance should be triggered by upkeep
    /// @dev Returns true if cooldown elapsed AND (needRefill OR needDeploy) >= minRebalanceAmount
    function canRebalance() external view returns (bool);

    /// @notice Get cached warm NAV state for O(1) staleness and validity check
    /// @dev Used by CoreVault.deposit()/mint() to enforce NAV freshness AND completeness.
    ///      If valid=false, deposit/mint MUST revert - NAV is incomplete (adapter failed).
    /// @return nav Cached warm NAV value
    /// @return ts Timestamp when cache was last updated
    /// @return valid True if ALL adapters responded successfully during last cache update
    function warmNavState() external view returns (uint256 nav, uint40 ts, bool valid);

    /// @notice Permissionless warm NAV cache refresh — no fund movement
    /// @dev Cache-maintenance primitive. Updates cachedWarmNav/lastWarmNavUpdate/warmNavValid.
    ///      Does NOT move funds, does NOT touch rebalance cooldown, does NOT interact with router.
    function refreshWarmNav() external;

    /// @notice esegue il refill (warm → hot). Muove fondi dall'adapter al Core.
    function refill(uint256 amount) external;

    /// @notice Force refill for forceWithdraw path — returns result, no silent failure.
    /// @dev No slippage check, no revert on adapter failure. Emits ForceRefillFailed if needed.
    /// @return ok True if any funds were pulled
    /// @return pulled Amount of USDC actually transferred to vault
    function forceRefill(uint256 amount) external returns (bool ok, uint256 pulled);

    function realizeForReserveAndOps(uint256 maxAmount) external returns (uint256 pulled);

    /// @notice prepara il deploy calcolando la delta (hot → warm) che il Core dovrà trasferire all'adapter.
    /// @return amount da spostare Core→adapter per raggiungere targetHot
    function prepareDeploy() external view returns (uint256 amount);

    /// @notice completa il deploy (hot → warm) **dopo** che il Core ha trasferito `amount` all'adapter.
    /// Deposita nell'adapter. Solo il Core può chiamarla.
    function executeDeploy(uint256 amount) external;

    /// @notice solo ruoli autorizzati (admin/risk)
    function updateConfig(BufferConfig calldata cfg) external;
    function setPaused(bool p) external;

    // A5: Multi-adapter management
    /// @notice Get list of warm adapters
    /// @return Array of warm adapter addresses
    function getWarmAdapters() external view returns (address[] memory);

    /// @notice Add a warm adapter to the list
    /// @param adapter Address of the adapter to add
    function addWarmAdapter(address adapter) external;

    /// @notice Remove a warm adapter from the list
    /// @param index Index of the adapter to remove
    function removeWarmAdapter(uint256 index) external;

    /// @notice Reset the warm adapters list in one call (overwrites existing)
    /// @param adapters New list of warm adapters
    function setWarmAdapters(address[] calldata adapters) external;
}
