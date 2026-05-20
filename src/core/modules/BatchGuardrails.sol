// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IConfig } from "../../interfaces/IConfig.sol";
import { IPriceOracleMiddleware } from "../../interfaces/IPriceOracleMiddleware.sol";

/**
 * @title BatchGuardrails
 * @notice Helper contract for validating batch operations before execution
 * @dev Can be used as a standalone validator or integrated into routers
 *
 * Guardrails enforced:
 * - Max actions per batch (from Config)
 * - Cooldown (via Vault.canRebalance())
 * - NAV delta validation (from Config)
 * - Adapter allowlist (from Config)
 * - Adapter caps (from Config)
 * - Oracle freshness (via PriceOracleMiddleware)
 */
contract BatchGuardrails {
    /* ========== STATE VARIABLES ========== */

    IConfig public immutable config;
    IPriceOracleMiddleware public immutable oracle;
    address public immutable vault;

    /* ========== EVENTS ========== */

    event BatchGuardFailed(string reason, uint256 value, uint256 limit);
    event AdapterCapExceededEvent(address indexed adapter, uint256 allocation, uint256 cap);
    event NAVDeltaExceededEvent(
        uint256 oldNAV, uint256 newNAV, uint256 deltaBps, uint256 maxDeltaBps
    );

    /* ========== ERRORS ========== */

    error TooManyActions(uint256 count, uint256 max);
    error CooldownNotElapsed(uint256 elapsed, uint256 required);
    error NAVDeltaTooLarge(uint256 deltaBps, uint256 maxDeltaBps);
    error AdapterNotAllowed(address adapter);
    error AdapterCapExceeded(address adapter, uint256 amount, uint256 cap);
    error OraclePriceStale(address asset);
    error ZeroAddress();

    /* ========== CONSTRUCTOR ========== */

    constructor(address config_, address oracle_, address vault_) {
        if (config_ == address(0)) revert ZeroAddress();
        if (oracle_ == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();

        config = IConfig(config_);
        oracle = IPriceOracleMiddleware(oracle_);
        vault = vault_;
    }

    /* ========== VALIDATION FUNCTIONS ========== */

    /**
     * @notice Check max actions per batch
     * @param actionCount Number of actions
     */
    function checkMaxActions(uint256 actionCount) public view {
        uint256 maxActions = config.maxActionsPerBatch();
        if (actionCount > maxActions) {
            revert TooManyActions(actionCount, maxActions);
        }
    }

    /**
     * @notice Check cooldown via vault
     */
    function checkCooldown() public view {
        (bool success, bytes memory data) =
            vault.staticcall(abi.encodeWithSignature("canRebalance()"));
        require(success && data.length == 32, "canRebalance() call failed");
        bool canRebalance = abi.decode(data, (bool));

        if (!canRebalance) {
            (success, data) = vault.staticcall(abi.encodeWithSignature("minRebalanceCooldown()"));
            uint256 required = success && data.length == 32 ? abi.decode(data, (uint256)) : 0;

            (success, data) = vault.staticcall(abi.encodeWithSignature("lastBatchTs()"));
            uint48 lastBatch =
                success && data.length >= 32 ? uint48(abi.decode(data, (uint256))) : 0;

            uint256 elapsed = block.timestamp > lastBatch ? block.timestamp - lastBatch : 0;
            revert CooldownNotElapsed(elapsed, required);
        }
    }

    /**
     * @notice Check oracle price freshness
     * @param asset Asset address to check
     */
    function checkOracleFreshness(address asset) public view {
        if (!oracle.isFresh(asset)) {
            revert OraclePriceStale(asset);
        }
    }

    /**
     * @notice Check adapter allowlist
     * @param adapter Adapter address
     */
    function checkAdapterAllowed(address adapter) public view {
        if (!config.isAdapterAllowed(adapter)) {
            revert AdapterNotAllowed(adapter);
        }
    }

    /**
     * @notice Check adapter cap
     * @param adapter Adapter address
     * @param amount Amount to allocate
     */
    function checkAdapterCap(address adapter, uint256 amount) public view {
        uint256 cap = config.adapterCap(adapter);
        if (cap > 0 && amount > cap) {
            revert AdapterCapExceeded(adapter, amount, cap);
        }
    }

    /**
     * @notice Check NAV delta
     * @param navBefore NAV before operation
     * @param navAfter NAV after operation
     */
    function checkNAVDelta(uint256 navBefore, uint256 navAfter) public view {
        if (navBefore == 0) return; // First operation

        uint256 maxDeltaBps = config.maxNavDeltaBps();
        uint256 deltaBps;

        if (navAfter > navBefore) {
            deltaBps = ((navAfter - navBefore) * 10000) / navBefore;
        } else if (navBefore > navAfter) {
            deltaBps = ((navBefore - navAfter) * 10000) / navBefore;
        } else {
            return; // No change
        }

        if (deltaBps > maxDeltaBps) {
            revert NAVDeltaTooLarge(deltaBps, maxDeltaBps);
        }
    }

    /* ========== BATCH VALIDATION FUNCTIONS ========== */

    /**
     * @notice Validate deposit batch (all checks except cooldown/NAV delta)
     * @param adapters Array of adapter addresses
     * @param amounts Array of amounts
     * @param asset Asset address for oracle check
     */
    function validateDepositBatch(
        address[] calldata adapters,
        uint256[] calldata amounts,
        address asset
    ) external view {
        require(adapters.length == amounts.length, "length mismatch");

        uint256 adapterLen = adapters.length;
        checkMaxActions(adapterLen);
        checkOracleFreshness(asset);

        for (uint256 i = 0; i < adapterLen; i++) {
            checkAdapterAllowed(adapters[i]);
            checkAdapterCap(adapters[i], amounts[i]);
        }
    }

    /**
     * @notice Validate redeem batch (all checks including cooldown/NAV delta)
     * @param actionCount Number of actions
     * @param asset Asset address for oracle check
     * @param navBefore NAV before operation
     * @param navAfter NAV after operation
     */
    function validateRedeemBatch(
        uint256 actionCount,
        address asset,
        uint256 navBefore,
        uint256 navAfter
    ) external view {
        checkMaxActions(actionCount);
        checkCooldown();
        checkOracleFreshness(asset);
        checkNAVDelta(navBefore, navAfter);
    }

    /* ========== VIEW FUNCTIONS (NON-REVERTING) ========== */

    /**
     * @notice Check if deposit batch would pass (non-reverting)
     * @param adapters Array of adapter addresses
     * @param amounts Array of amounts
     * @param asset Asset address
     * @return pass True if all checks pass
     * @return reason Failure reason if any
     */
    function checkDepositBatch(
        address[] calldata adapters,
        uint256[] calldata amounts,
        address asset
    ) external view returns (bool pass, string memory reason) {
        if (adapters.length != amounts.length) {
            return (false, "LengthMismatch");
        }

        uint256 maxActions = config.maxActionsPerBatch();
        if (adapters.length > maxActions) {
            return (false, "TooManyActions");
        }

        if (!oracle.isFresh(asset)) {
            return (false, "OraclePriceStale");
        }

        uint256 adaptersLen = adapters.length;
        for (uint256 i = 0; i < adaptersLen; i++) {
            if (!config.isAdapterAllowed(adapters[i])) {
                return (false, "AdapterNotAllowed");
            }
            uint256 cap = config.adapterCap(adapters[i]);
            if (cap > 0 && amounts[i] > cap) {
                return (false, "AdapterCapExceeded");
            }
        }

        return (true, "");
    }

    /**
     * @notice Check if redeem batch would pass (non-reverting)
     * @param actionCount Number of actions
     * @param asset Asset address
     * @return pass True if all checks pass
     * @return reason Failure reason if any
     */
    function checkRedeemBatch(uint256 actionCount, address asset)
        external
        view
        returns (bool pass, string memory reason)
    {
        uint256 maxActions = config.maxActionsPerBatch();
        if (actionCount > maxActions) {
            return (false, "TooManyActions");
        }

        (bool success, bytes memory data) =
            vault.staticcall(abi.encodeWithSignature("canRebalance()"));
        if (!success || data.length != 32 || !abi.decode(data, (bool))) {
            return (false, "CooldownNotElapsed");
        }

        if (!oracle.isFresh(asset)) {
            return (false, "OraclePriceStale");
        }

        return (true, "");
    }
}
