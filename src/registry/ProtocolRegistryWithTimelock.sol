// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ProtocolRegistryWithTimelock
 * @notice Registry con Timelock per tutte le modifiche critiche + Multisig support
 * @dev SICUREZZA PRIMA DI TUTTO:
 *      - Tutte le modifiche hanno timelock obbligatorio
 *      - Multisig richiesto per accettare modifiche
 *      - Emergency pause per sicurezza
 *      - Vetoer può bloccare modifiche malevole
 */
contract ProtocolRegistryWithTimelock is AccessControl {
    // ===== Roles =====
    bytes32 public constant REGISTRY_ADMIN = keccak256("REGISTRY_ADMIN"); // Propone modifiche
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE"); // Esegue dopo timelock
    bytes32 public constant VETOER_ROLE = keccak256("VETOER_ROLE"); // Può bloccare
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE"); // Emergency pause

    // ===== Protocol Types =====
    enum ProtocolType {
        AAVE_V3,
        EULER_V2,
        MORPHO,
        COMPOUND_V3,
        DOLOMITE,
        GAINS,
        SILO_V2
    }

    // ===== Timelock Configuration =====
    uint256 public constant MIN_DELAY = 2 days; // Minimo 2 giorni
    uint256 public constant MAX_DELAY = 30 days; // Massimo 30 giorni
    uint256 public constant GRACE_PERIOD = 7 days; // Finestra esecuzione

    uint256 public delay = 3 days; // Default: 3 giorni

    // ===== Emergency =====
    bool public paused;

    // ===== Storage =====

    // Protocol core addresses
    mapping(ProtocolType => address) public protocolCore;

    // Vaults per protocol
    mapping(ProtocolType => mapping(uint256 => address)) public vaults;
    mapping(ProtocolType => uint256) public vaultCount;
    mapping(ProtocolType => mapping(address => bool)) public isVaultEnabled;

    // Metadata
    struct VaultMetadata {
        string name;
        uint16 riskScoreBps;
        uint256 maxCapacity;
        bool verified;
    }
    mapping(ProtocolType => mapping(address => VaultMetadata)) public vaultMetadata;

    // ===== Timelock Queue =====
    enum ActionType {
        ADD_VAULT,
        REMOVE_VAULT,
        ENABLE_VAULT,
        DISABLE_VAULT,
        SET_PROTOCOL_CORE,
        UPDATE_METADATA,
        UPDATE_DELAY
    }

    struct QueuedAction {
        ActionType actionType;
        ProtocolType protocol;
        address target; // vault or core address
        bytes data; // encoded action data
        uint256 eta; // execution timestamp
        bool executed;
        bool vetoed;
    }

    QueuedAction[] public queue;
    mapping(bytes32 => uint256) public actionIndex; // hash => queue index

    // ===== Events =====
    event ActionQueued(
        uint256 indexed index,
        ActionType indexed actionType,
        ProtocolType protocol,
        address target,
        uint256 eta
    );
    event ActionExecuted(uint256 indexed index, bytes32 indexed actionHash);
    event ActionVetoed(uint256 indexed index, bytes32 indexed actionHash);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event EmergencyPaused(bool paused);

    // ===== Modifiers =====
    modifier notPaused() {
        require(!paused, "Registry: paused");
        _;
    }

    modifier onlyExecutor() {
        require(hasRole(EXECUTOR_ROLE, msg.sender), "Registry: not executor");
        _;
    }

    // ===== Constructor =====
    constructor(address admin, address multisig) {
        require(admin != address(0), "zero admin");
        require(multisig != address(0), "zero multisig");

        // Admin può proporre
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_ADMIN, admin);

        // Multisig DEVE eseguire (sicurezza!)
        _grantRole(EXECUTOR_ROLE, multisig);

        // Admin può essere vetoer (opzionale: dare a indirizzo diverso)
        _grantRole(VETOER_ROLE, admin);

        // Emergency role (opzionale: dare a guardian)
        _grantRole(EMERGENCY_ROLE, admin);
    }

    // ===== Timelock Functions =====

    /**
     * @notice Queue: Aggiungi vault (con timelock)
     * @dev Solo REGISTRY_ADMIN può proporre
     */
    function queueAddVault(ProtocolType protocol, address vault)
        external
        onlyRole(REGISTRY_ADMIN)
        notPaused
        returns (uint256 index)
    {
        require(vault != address(0), "zero address");

        bytes memory data = abi.encode(vault);
        uint256 eta = block.timestamp + delay;

        index = queue.length;
        queue.push(
            QueuedAction({
                actionType: ActionType.ADD_VAULT,
                protocol: protocol,
                target: vault,
                data: data,
                eta: eta,
                executed: false,
                vetoed: false
            })
        );

        bytes32 actionHash = _getActionHash(index);
        actionIndex[actionHash] = index;

        emit ActionQueued(index, ActionType.ADD_VAULT, protocol, vault, eta);
        return index;
    }

    /**
     * @notice Execute: Esegui aggiunta vault (dopo timelock)
     * @dev Solo EXECUTOR_ROLE (multisig) può eseguire
     */
    function executeAddVault(uint256 index) external onlyExecutor notPaused {
        QueuedAction storage action = queue[index];

        require(!action.executed, "already executed");
        require(!action.vetoed, "vetoed");
        require(action.actionType == ActionType.ADD_VAULT, "wrong action");
        require(block.timestamp >= action.eta, "timelock not passed");
        require(block.timestamp <= action.eta + GRACE_PERIOD, "grace period expired");

        action.executed = true;

        // Execute action
        address vault = abi.decode(action.data, (address));
        _addVaultInternal(action.protocol, vault);

        emit ActionExecuted(index, _getActionHash(index));
    }

    /**
     * @notice Queue: Rimuovi vault
     */
    function queueRemoveVault(ProtocolType protocol, uint256 vaultIndex)
        external
        onlyRole(REGISTRY_ADMIN)
        notPaused
        returns (uint256 index)
    {
        require(vaultIndex < vaultCount[protocol], "invalid index");

        bytes memory data = abi.encode(vaultIndex);
        uint256 eta = block.timestamp + delay;

        index = queue.length;
        queue.push(
            QueuedAction({
                actionType: ActionType.REMOVE_VAULT,
                protocol: protocol,
                target: vaults[protocol][vaultIndex],
                data: data,
                eta: eta,
                executed: false,
                vetoed: false
            })
        );

        emit ActionQueued(
            index, ActionType.REMOVE_VAULT, protocol, vaults[protocol][vaultIndex], eta
        );
        return index;
    }

    /**
     * @notice Execute: Rimuovi vault
     */
    function executeRemoveVault(uint256 index) external onlyExecutor notPaused {
        QueuedAction storage action = queue[index];

        require(!action.executed, "already executed");
        require(!action.vetoed, "vetoed");
        require(action.actionType == ActionType.REMOVE_VAULT, "wrong action");
        require(block.timestamp >= action.eta, "timelock not passed");
        require(block.timestamp <= action.eta + GRACE_PERIOD, "grace period expired");

        action.executed = true;

        uint256 vaultIndex = abi.decode(action.data, (uint256));
        _removeVaultInternal(action.protocol, vaultIndex);

        emit ActionExecuted(index, _getActionHash(index));
    }

    /**
     * @notice Queue: Enable/Disable vault
     */
    function queueSetVaultEnabled(ProtocolType protocol, address vault, bool enabled)
        external
        onlyRole(REGISTRY_ADMIN)
        notPaused
        returns (uint256 index)
    {
        bytes memory data = abi.encode(vault, enabled);
        uint256 eta = block.timestamp + delay;

        ActionType actionType = enabled ? ActionType.ENABLE_VAULT : ActionType.DISABLE_VAULT;

        index = queue.length;
        queue.push(
            QueuedAction({
                actionType: actionType,
                protocol: protocol,
                target: vault,
                data: data,
                eta: eta,
                executed: false,
                vetoed: false
            })
        );

        emit ActionQueued(index, actionType, protocol, vault, eta);
        return index;
    }

    /**
     * @notice Execute: Enable/Disable vault
     */
    function executeSetVaultEnabled(uint256 index) external onlyExecutor notPaused {
        QueuedAction storage action = queue[index];

        require(!action.executed, "already executed");
        require(!action.vetoed, "vetoed");
        require(
            action.actionType == ActionType.ENABLE_VAULT
                || action.actionType == ActionType.DISABLE_VAULT,
            "wrong action"
        );
        require(block.timestamp >= action.eta, "timelock not passed");
        require(block.timestamp <= action.eta + GRACE_PERIOD, "grace period expired");

        action.executed = true;

        (address vault, bool enabled) = abi.decode(action.data, (address, bool));
        _setVaultEnabledInternal(action.protocol, vault, enabled);

        emit ActionExecuted(index, _getActionHash(index));
    }

    // ===== Veto Functions =====

    /**
     * @notice Veto una modifica in queue
     * @dev Solo VETOER_ROLE può bloccare (sicurezza contro modifiche malevole)
     */
    function vetoAction(uint256 index) external onlyRole(VETOER_ROLE) {
        QueuedAction storage action = queue[index];

        require(!action.executed, "already executed");
        require(!action.vetoed, "already vetoed");

        action.vetoed = true;

        emit ActionVetoed(index, _getActionHash(index));
    }

    // ===== Emergency Functions =====

    /**
     * @notice Emergency pause (blocca TUTTE le operazioni)
     * @dev Solo EMERGENCY_ROLE
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        paused = true;
        emit EmergencyPaused(true);
    }

    /**
     * @notice Unpause
     */
    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        paused = false;
        emit EmergencyPaused(false);
    }

    // ===== Internal Functions =====

    function _addVaultInternal(ProtocolType protocol, address vault) internal {
        uint256 index = vaultCount[protocol];
        vaults[protocol][index] = vault;
        vaultCount[protocol]++;
        isVaultEnabled[protocol][vault] = true;
    }

    function _removeVaultInternal(ProtocolType protocol, uint256 index) internal {
        address vault = vaults[protocol][index];
        vaults[protocol][index] = address(0);
        isVaultEnabled[protocol][vault] = false;
    }

    function _setVaultEnabledInternal(ProtocolType protocol, address vault, bool enabled) internal {
        isVaultEnabled[protocol][vault] = enabled;
    }

    function _getActionHash(uint256 index) internal view returns (bytes32) {
        QueuedAction memory action = queue[index];
        return keccak256(
            abi.encode(action.actionType, action.protocol, action.target, action.data, action.eta)
        );
    }

    // ===== View Functions =====

    /**
     * @notice Get enabled vaults (SICURO: solo vaults attivi)
     */
    function getEnabledVaults(ProtocolType protocol)
        external
        view
        returns (address[] memory enabledVaults)
    {
        uint256 count = vaultCount[protocol];
        uint256 enabledCount = 0;

        for (uint256 i = 0; i < count; i++) {
            address vault = vaults[protocol][i];
            if (vault != address(0) && isVaultEnabled[protocol][vault]) {
                enabledCount++;
            }
        }

        enabledVaults = new address[](enabledCount);
        uint256 index = 0;
        for (uint256 i = 0; i < count; i++) {
            address vault = vaults[protocol][i];
            if (vault != address(0) && isVaultEnabled[protocol][vault]) {
                enabledVaults[index] = vault;
                index++;
            }
        }

        return enabledVaults;
    }

    /**
     * @notice Get queued action details
     */
    function getQueuedAction(uint256 index)
        external
        view
        returns (
            ActionType actionType,
            ProtocolType protocol,
            address target,
            uint256 eta,
            bool executed,
            bool vetoed,
            bool canExecute
        )
    {
        QueuedAction memory action = queue[index];

        canExecute = !action.executed && !action.vetoed && block.timestamp >= action.eta
            && block.timestamp <= action.eta + GRACE_PERIOD;

        return (
            action.actionType,
            action.protocol,
            action.target,
            action.eta,
            action.executed,
            action.vetoed,
            canExecute
        );
    }

    /**
     * @notice Get total queued actions
     */
    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    /**
     * @notice Check if vault is enabled
     */
    function isEnabled(ProtocolType protocol, address vault) external view returns (bool) {
        return isVaultEnabled[protocol][vault];
    }

    // ===== Admin Functions =====

    /**
     * @notice Update timelock delay (con timelock!)
     */
    function queueUpdateDelay(uint256 newDelay)
        external
        onlyRole(REGISTRY_ADMIN)
        notPaused
        returns (uint256 index)
    {
        require(newDelay >= MIN_DELAY, "delay too short");
        require(newDelay <= MAX_DELAY, "delay too long");

        bytes memory data = abi.encode(newDelay);
        uint256 eta = block.timestamp + delay;

        index = queue.length;
        queue.push(
            QueuedAction({
                actionType: ActionType.UPDATE_DELAY,
                protocol: ProtocolType.AAVE_V3, // Dummy
                target: address(0),
                data: data,
                eta: eta,
                executed: false,
                vetoed: false
            })
        );

        emit ActionQueued(index, ActionType.UPDATE_DELAY, ProtocolType.AAVE_V3, address(0), eta);
        return index;
    }

    /**
     * @notice Execute delay update
     */
    function executeUpdateDelay(uint256 index) external onlyExecutor notPaused {
        QueuedAction storage action = queue[index];

        require(!action.executed, "already executed");
        require(!action.vetoed, "vetoed");
        require(action.actionType == ActionType.UPDATE_DELAY, "wrong action");
        require(block.timestamp >= action.eta, "timelock not passed");

        action.executed = true;

        uint256 newDelay = abi.decode(action.data, (uint256));
        uint256 oldDelay = delay;
        delay = newDelay;

        emit DelayUpdated(oldDelay, newDelay);
        emit ActionExecuted(index, _getActionHash(index));
    }
}
