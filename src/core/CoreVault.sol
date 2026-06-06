// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IParamsProvider } from "../interfaces/IParamsProvider.sol";
import { IBufferManager } from "../interfaces/IBufferManager.sol";
import { IStrategyRouter } from "../interfaces/IStrategyRouter.sol";
import { IStrategyHealthRegistry } from "../interfaces/IStrategyHealthRegistry.sol";
import { IIncentives } from "../interfaces/IIncentives.sol";
import { ICoreVault } from "../interfaces/ICoreVault.sol";
import { CoreStorage } from "./storage/CoreStorage.sol";
import { FeeStorage } from "./storage/FeeStorage.sol";
import { QueueStorage } from "./storage/QueueStorage.sol";
import { Events } from "./libraries/Events.sol";
import { Percentage } from "../libs/Percentage.sol";
import { SelectorRegistry } from "./libraries/SelectorRegistry.sol";

/// @title CoreVault v8 (Diamond-lite Thin Proxy)
/// @notice ERC-4626 vault that delegates ALL economic logic to modules via delegatecall.
///
/// CRITICAL INVARIANT:
///   CoreVault MUST NOT implement fee logic, asset transfer logic, or accounting logic.
///   All economic behavior MUST be implemented in modules (ERC4626Module, QueueModule, AdminModule).
///   CoreVault acts ONLY as: dispatcher + access control gate.
///
/// @dev The ERC-4626 public functions (deposit, withdraw, redeem, mint) are thin wrappers
///      that delegate to the ERC4626Module. This ensures:
///      1. Single source of truth for fee logic (ExitFeeLib)
///      2. Module swappability for all economic paths
///      3. No fee desynchronization between paths
contract CoreVault is ERC4626, ICoreVault {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error NotOwner();
    error NotGuardian();
    error NotOwnerOrGuardian();
    error NotModule();
    error Paused();
    error DepositsPaused();
    error WithdrawalsPaused();
    error ZeroAmount();
    error ZeroAddress();
    error RoutingFrozen();
    error ModuleNotSet();
    error DelegatecallFailed();
    error NoTransferPending();
    error GuardianCooldownActive();
    error ReentrancyGuardLocked();
    error InvalidRoleForSelector(bytes4 selector, uint8 attemptedRole, uint8 requiredRole);
    error SelectorRegistryAlreadySet();
    error SystemSealed();
    error SealerAlreadySet();
    error NotAuthorizedSealer();
    error InvalidConfigHash();
    error SealNotPrepared();
    error SealHashMismatch(bytes32 pending, bytes32 expected);
    error RoutingNotFrozen();
    error NotAuthorizedModule();

    // ═══════════════════════════════════════════════════════════════════════════════
    // ROLE CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════
    uint8 public constant ROLE_PUBLIC = 0;
    uint8 public constant ROLE_OWNER = 1;
    uint8 public constant ROLE_GUARDIAN = 2;
    uint8 public constant ROLE_OWNER_OR_GUARDIAN = 3;
    uint8 public constant ROLE_MODULE = 4;

    // ═══════════════════════════════════════════════════════════════════════════════
    // OPS NAV CACHE (for gas-sensitive decisions — NOT for fee/PPS math)
    // ═══════════════════════════════════════════════════════════════════════════════
    uint256 internal _opsNavCache;
    uint64 internal _opsNavCacheTs;
    uint32 public opsNavCacheTtl = 60; // 60 seconds default

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════
    constructor(
        IERC20Metadata _asset,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _feeCollector,
        address _params
    ) ERC20(_name, _symbol) ERC4626(_asset) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_feeCollector == address(0)) revert ZeroAddress();

        CoreStorage.Layout storage core = CoreStorage.layout();
        core.owner = _owner;
        core.feeCollector = _feeCollector;
        core.params = IParamsProvider(_params);
        core.epochStart = uint64(block.timestamp);
        core.epochDuration = 7 days; // default 7d, adjustable via admin within [1d, 30d]
        core.paramMinDelay = 0; // Bootstrap: zero delay. Owner MUST set to 2 days post-setup.

        // v8: Start paused — unpause only after full wiring verification
        core.packedFlags |= CoreStorage.FLAG_PAUSED;

        emit Events.OwnershipTransferred(address(0), _owner);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════
    modifier onlyOwner() {
        if (msg.sender != CoreStorage.layout().owner) revert NotOwner();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != CoreStorage.layout().guardian) revert NotGuardian();
        _;
    }

    modifier nonReentrant() {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_REENTRANCY_LOCKED != 0) {
            revert ReentrancyGuardLocked();
        }
        core.packedFlags |= CoreStorage.FLAG_REENTRANCY_LOCKED;
        _;
        core.packedFlags &= ~CoreStorage.FLAG_REENTRANCY_LOCKED;
    }

    modifier onlyAuthorizedModule() {
        if (!CoreStorage.layout().isAuthorizedModule[msg.sender]) revert NotAuthorizedModule();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FALLBACK ROUTER (diamond-lite dispatch to modules)
    // ═══════════════════════════════════════════════════════════════════════════════

    fallback() external payable {
        CoreStorage.Layout storage core = CoreStorage.layout();

        address module = core.moduleOf[msg.sig];
        if (module == address(0)) revert ModuleNotSet();

        // Role-based access control
        uint8 role = core.roleOf[msg.sig];
        if (role == ROLE_OWNER) {
            if (msg.sender != core.owner) revert NotOwner();
        } else if (role == ROLE_GUARDIAN) {
            if (msg.sender != core.guardian) revert NotGuardian();
        } else if (role == ROLE_OWNER_OR_GUARDIAN) {
            if (msg.sender != core.owner && msg.sender != core.guardian) {
                revert NotOwnerOrGuardian();
            }
        } else if (role == ROLE_MODULE) {
            if (msg.sender != address(this)) revert NotModule();
        }
        // ROLE_PUBLIC (0) = no restrictions

        // Delegatecall to module
        (bool success, bytes memory result) = module.delegatecall(msg.data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert DelegatecallFailed();
        }
        assembly {
            return(add(result, 32), mload(result))
        }
    }

    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERC-4626 THIN WRAPPERS — delegate ALL logic to ERC4626Module
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // CRITICAL: These functions contain NO fee logic, NO accounting, NO asset transfers.
    // They ONLY dispatch to the module registered for their selector.
    // The ERC4626Module handles everything via ExitFeeLib.
    //

    // NOTE: NO nonReentrant on these wrappers — the module handles reentrancy
    // guard via _enterNonReentrant/_exitNonReentrant in delegatecall context
    // (same storage slot). Adding nonReentrant here would double-lock.

    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        bytes memory result = _delegateToModule(msg.sig, msg.data);
        shares = abi.decode(result, (uint256));
        _refreshOpsNavCache();
    }

    function mint(uint256 shares, address receiver)
        public
        override
        returns (uint256 assets)
    {
        bytes memory result = _delegateToModule(msg.sig, msg.data);
        assets = abi.decode(result, (uint256));
        _refreshOpsNavCache();
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        returns (uint256 shares)
    {
        bytes memory result = _delegateToModule(msg.sig, msg.data);
        shares = abi.decode(result, (uint256));
        _refreshOpsNavCache();
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        returns (uint256 assets)
    {
        bytes memory result = _delegateToModule(msg.sig, msg.data);
        assets = abi.decode(result, (uint256));
        _refreshOpsNavCache();
    }

    /// @dev Internal: dispatch to module registered for the given selector
    function _delegateToModule(bytes4 sel, bytes calldata data) internal returns (bytes memory) {
        address module = CoreStorage.layout().moduleOf[sel];
        if (module == address(0)) revert ModuleNotSet();

        (bool success, bytes memory result) = module.delegatecall(data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert DelegatecallFailed();
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODULE ROUTING ADMIN
    // ═══════════════════════════════════════════════════════════════════════════════

    function setSelectorRegistry(address registry) external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.selectorRegistry != address(0)) revert SelectorRegistryAlreadySet();
        core.selectorRegistry = registry;
        emit Events.SelectorRegistrySet(registry);
    }

    function setModule(bytes4 selector, address module, uint8 role) external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_ROUTING_FROZEN != 0) revert RoutingFrozen();
        _validateRoleAssignment(core, selector, role);
        core.moduleOf[selector] = module;
        core.roleOf[selector] = role;
        emit Events.ModuleSet(selector, module, role);
    }

    function setModulesBatch(
        bytes4[] calldata selectors,
        address[] calldata modules,
        uint8[] calldata roles
    ) external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_ROUTING_FROZEN != 0) revert RoutingFrozen();

        uint256 len = selectors.length;
        require(len == modules.length && len == roles.length, "length mismatch");

        for (uint256 i; i < len;) {
            _validateRoleAssignment(core, selectors[i], roles[i]);
            core.moduleOf[selectors[i]] = modules[i];
            core.roleOf[selectors[i]] = roles[i];
            unchecked { ++i; }
        }
        emit Events.ModulesBatchSet(len);
    }

    function _validateRoleAssignment(CoreStorage.Layout storage core, bytes4 selector, uint8 role)
        internal
        view
    {
        address reg = core.selectorRegistry;
        if (reg == address(0)) return;
        // Delegate entirely to SelectorRegistry — single source of truth for role enforcement.
        // validateRoleAssignment handles ROLE_PUBLIC (0), ROLE_OWNER, and ROLE_UNREGISTERED
        // correctly without local reimplementation that can diverge.
        SelectorRegistry(reg).validateRoleAssignment(selector, role);
    }

    function freezeRouting() external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_ROUTING_FROZEN != 0) revert RoutingFrozen();
        core.packedFlags |= CoreStorage.FLAG_ROUTING_FROZEN;
        emit Events.RoutingFrozen();
    }

    function moduleOf(bytes4 selector) external view returns (address) {
        return CoreStorage.layout().moduleOf[selector];
    }

    function roleOf(bytes4 selector) external view returns (uint8) {
        return CoreStorage.layout().roleOf[selector];
    }

    function isRoutingFrozen() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_ROUTING_FROZEN != 0;
    }

    function selectorRegistry() external view returns (address) {
        return CoreStorage.layout().selectorRegistry;
    }

    function authorizedSealer() external view returns (address) {
        return CoreStorage.layout().authorizedSealer;
    }

    function pendingSealHash() external view returns (bytes32) {
        return CoreStorage.layout().pendingSealHash;
    }

    function authorizeModule(address module, bool authorized) external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();
        core.isAuthorizedModule[module] = authorized;
    }

    function isModuleAuthorized(address module) external view returns (bool) {
        return CoreStorage.layout().isAuthorizedModule[module];
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SEAL
    // ═══════════════════════════════════════════════════════════════════════════════

    function isSystemSealed() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0;
    }

    function setAuthorizedSealer(address sealer) external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();
        if (core.authorizedSealer != address(0)) revert SealerAlreadySet();
        core.authorizedSealer = sealer;
        emit Events.AuthorizedSealerSet(sealer);
    }

    function prepareSeal(bytes32 configHash) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();
        if (msg.sender != core.authorizedSealer) revert NotAuthorizedSealer();
        if (configHash == bytes32(0)) revert InvalidConfigHash();
        if (core.packedFlags & CoreStorage.FLAG_ROUTING_FROZEN == 0) revert RoutingNotFrozen();
        core.pendingSealHash = configHash;
        emit Events.SealPrepared(msg.sender, configHash);
    }

    function sealFinalState(bytes32 expectedHash) external onlyOwner {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();
        if (core.pendingSealHash == bytes32(0)) revert SealNotPrepared();
        if (core.pendingSealHash != expectedHash) {
            revert SealHashMismatch(core.pendingSealHash, expectedHash);
        }
        core.packedFlags |= CoreStorage.FLAG_SYSTEM_SEALED;
        emit Events.SystemSealed(msg.sender, expectedHash, block.timestamp);
    }

    /**
     * @notice Atomically record the verified config hash and seal in one call.
     * @dev Called by SystemSealer.verifyAndSeal() as a single timelock operation.
     *      Unlike the two-step prepareSeal/sealFinalState pattern, this function
     *      sets pendingSealHash and immediately activates the sealed flag so no
     *      separate executeBatch step is required.
     */
    function sealBySealer(bytes32 configHash) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.authorizedSealer) revert NotAuthorizedSealer();
        if (core.packedFlags & CoreStorage.FLAG_SYSTEM_SEALED != 0) revert SystemSealed();
        if (configHash == bytes32(0)) revert InvalidConfigHash();
        if (core.packedFlags & CoreStorage.FLAG_ROUTING_FROZEN == 0) revert RoutingNotFrozen();
        core.pendingSealHash = configHash;
        core.packedFlags |= CoreStorage.FLAG_SYSTEM_SEALED;
        emit Events.SystemSealed(msg.sender, configHash, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // OWNERSHIP
    // ═══════════════════════════════════════════════════════════════════════════════

    function owner() external view returns (address) {
        return CoreStorage.layout().owner;
    }

    function pendingOwner() external view returns (address) {
        return CoreStorage.layout().pendingOwner;
    }

    function beginOwnerTransfer(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        CoreStorage.layout().pendingOwner = newOwner;
        emit Events.OwnershipTransferInitiated(CoreStorage.layout().owner, newOwner);
    }

    function acceptOwnerTransfer() external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        if (msg.sender != core.pendingOwner) revert NoTransferPending();
        address old = core.owner;
        core.owner = msg.sender;
        core.pendingOwner = address(0);
        emit Events.OwnershipTransferred(old, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PAUSE
    // ═══════════════════════════════════════════════════════════════════════════════

    function paused() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_PAUSED != 0;
    }

    function pausedDeposits() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_PAUSED_DEPOSITS != 0;
    }

    function pausedWithdrawals() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_PAUSED_WITHDRAWALS != 0;
    }

    function pauseAll() external onlyOwner {
        CoreStorage.layout().packedFlags |= CoreStorage.FLAG_PAUSED;
        emit Events.AllPaused();
    }

    function unpauseAll() external onlyOwner {
        CoreStorage.layout().packedFlags &=
            ~(CoreStorage.FLAG_PAUSED | CoreStorage.FLAG_PAUSED_DEPOSITS | CoreStorage.FLAG_PAUSED_WITHDRAWALS);
        emit Events.AllUnpaused();
    }

    function pauseDepositsOnly(bool p) external onlyOwner {
        if (p) {
            CoreStorage.layout().packedFlags |= CoreStorage.FLAG_PAUSED_DEPOSITS;
            emit Events.DepositsPaused();
        } else {
            CoreStorage.layout().packedFlags &= ~CoreStorage.FLAG_PAUSED_DEPOSITS;
            emit Events.DepositsUnpaused();
        }
    }

    function pauseWithdrawalsOnly(bool p) external onlyOwner {
        if (p) {
            CoreStorage.layout().packedFlags |= CoreStorage.FLAG_PAUSED_WITHDRAWALS;
            emit Events.WithdrawalsPaused();
        } else {
            CoreStorage.layout().packedFlags &= ~CoreStorage.FLAG_PAUSED_WITHDRAWALS;
            emit Events.WithdrawalsUnpaused();
        }
    }

    function guardianPause() external onlyGuardian {
        CoreStorage.Layout storage core = CoreStorage.layout();
        uint64 cooldown = address(core.params) != address(0)
            ? core.params.guardianPauseCooldown(address(this))
            : 7 days;
        if (cooldown == 0) cooldown = 7 days;
        if (core.lastGuardianPause != 0 && block.timestamp < uint256(core.lastGuardianPause) + cooldown) {
            revert GuardianCooldownActive();
        }
        core.lastGuardianPause = uint64(block.timestamp);
        core.packedFlags |= CoreStorage.FLAG_PAUSED;
        emit Events.GuardianPauseActivated(msg.sender, block.timestamp);
    }

    function guardian() external view returns (address) {
        return CoreStorage.layout().guardian;
    }

    function setGuardian(address newGuardian) external onlyOwner {
        CoreStorage.layout().guardian = newGuardian;
        emit Events.GuardianUpdated(newGuardian);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // COMPONENT VIEWS
    // ═══════════════════════════════════════════════════════════════════════════════

    function feeCollector() external view returns (address) { return CoreStorage.layout().feeCollector; }
    function params() external view returns (IParamsProvider) { return CoreStorage.layout().params; }
    function bufferManager() external view returns (IBufferManager) { return CoreStorage.layout().bufferManager; }
    function router() external view returns (IStrategyRouter) { return CoreStorage.layout().router; }
    function healthRegistry() external view returns (IStrategyHealthRegistry) { return CoreStorage.layout().healthRegistry; }
    function incentives() external view returns (IIncentives) { return CoreStorage.layout().incentives; }
    function vetoer() external view returns (address) { return CoreStorage.layout().vetoer; }

    // ═══════════════════════════════════════════════════════════════════════════════
    // TOTAL ASSETS — CANONICAL (ERC-4626, LIVE, never stale)
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // CRITICAL: This is the ONLY function used for fee math, PPS, convertToAssets.
    // It always computes live. _cachedNavForOps() is a SEPARATE cache for gas-sensitive
    // decisions and MUST NOT be used for economic calculations.
    //

    function totalAssets() public view override(ERC4626, ICoreVault) returns (uint256) {
        (uint256 hot, uint256 strat, uint256 warm) = _totalAssetsBreakdown();
        return hot + strat + warm;
    }

    function _totalAssets() internal view returns (uint256) {
        (uint256 hot, uint256 strat, uint256 warm) = _totalAssetsBreakdown();
        return hot + strat + warm;
    }

    function _totalAssetsBreakdown()
        internal
        view
        returns (uint256 hot, uint256 strat, uint256 warm)
    {
        CoreStorage.Layout storage core = CoreStorage.layout();
        hot = IERC20(asset()).balanceOf(address(this));

        IStrategyRouter r = core.router;
        if (address(r) != address(0)) {
            strat = r.totalStrategyAssetsSafe();
        }

        IBufferManager bm = core.bufferManager;
        if (address(bm) != address(0)) {
            (warm,,) = bm.warmNavState();
        }
    }

    function totalAssetsBreakdown() external view returns (uint256 nav, uint256 hot, uint256 warm) {
        uint256 strat;
        (hot, strat, warm) = _totalAssetsBreakdown();
        nav = hot + strat + warm;
    }

    function asset() public view override(ERC4626, ICoreVault) returns (address) {
        return ERC4626.asset();
    }

    function decimals() public view override(ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Returns 0 — withdraw() always reverts (queued protocol).
    /// @dev ERC4626 compliant: "MUST return 0 if withdraw would revert."
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Returns 0 — redeem() always reverts (queued protocol).
    /// @dev ERC4626 compliant: "MUST return 0 if redeem would revert."
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!_depositsAreCurrentlyAllowed()) return 0;

        IParamsProvider.DepositLimits memory limits =
            CoreStorage.layout().params.getDepositLimits(address(this));
        uint256 remaining = type(uint256).max;

        if (limits.vaultDepositCap > 0) {
            uint256 total = _totalAssets();
            if (total >= limits.vaultDepositCap) return 0;
            remaining = limits.vaultDepositCap - total;
        }

        if (limits.userDepositCap > 0) {
            uint256 userAssets = convertToAssets(balanceOf(receiver));
            if (userAssets >= limits.userDepositCap) return 0;
            uint256 userRemaining = limits.userDepositCap - userAssets;
            if (userRemaining < remaining) remaining = userRemaining;
        }

        if (
            limits.minDepositAmount > 0 && remaining != type(uint256).max
                && remaining < limits.minDepositAmount
        ) {
            return 0;
        }

        return remaining;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets_ = maxDeposit(receiver);
        if (maxAssets_ == 0) return 0;
        if (maxAssets_ == type(uint256).max) return type(uint256).max;
        return previewDeposit(maxAssets_);
    }

    /// @notice Returns net shares the caller would receive for `assets` deposited.
    /// @dev ERC4626: "MUST return as close to and no fewer than the exact amount of shares
    ///      that would be minted in a deposit call in the same transaction."
    ///      Since deposit() deducts a deposit fee, previewDeposit must reflect net shares.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint16 depBps = FeeStorage.layout().fee.depBps;
        if (depBps == 0) return super.previewDeposit(assets);
        uint256 feeA = assets * uint256(depBps) / 10000;
        return super.previewDeposit(assets - feeA);
    }

    /// @notice Returns gross assets needed to mint `shares` (includes deposit fee).
    /// @dev ERC4626: "MUST return as close to and no fewer than the exact amount of assets
    ///      that would be deposited in a mint call in the same transaction."
    ///      Since mint() charges a deposit fee on top, previewMint must include it.
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = super.previewMint(shares);
        uint16 depBps = FeeStorage.layout().fee.depBps;
        if (depBps == 0) return netAssets;
        uint256 denom = 10000 - uint256(depBps);
        // Gross-up: ceil(net * 10000 / (10000 - f))
        return (netAssets * 10000 + denom - 1) / denom;
    }

    function _depositsAreCurrentlyAllowed() internal view returns (bool) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        uint256 flags = core.packedFlags;
        if (flags & CoreStorage.FLAG_PAUSED != 0) return false;
        if (flags & CoreStorage.FLAG_PAUSED_DEPOSITS != 0) return false;

        IBufferManager bm = core.bufferManager;
        if (address(bm) == address(0)) return false;
        (, uint40 ts, bool valid) = bm.warmNavState();
        if (!valid) return false;
        return block.timestamp <= uint256(ts) + 15 minutes;
    }

    // NOTE: previewWithdraw/previewRedeem keep OZ defaults (share/asset conversion).
    // They are used internally by forceWithdraw for baseShares computation.
    // maxWithdraw=0 and maxRedeem=0 already signal that standard withdrawal is disabled.

    // ═══════════════════════════════════════════════════════════════════════════════
    // OPS NAV CACHE — for gas-sensitive decisions ONLY
    // ═══════════════════════════════════════════════════════════════════════════════
    //
    // CRITICAL RULE — Cache usage boundary:
    //   ALLOWED: checkUpkeep, plan(), BM routing, pre-check gas-sensitive
    //   FORBIDDEN: convertToAssets, convertToShares, fee math, mint/burn, payout
    //

    /// @notice Returns cached NAV for operational decisions (NOT for economic math)
    /// @return nav The cached total assets value
    /// @return valid True if cache is fresh (within TTL)
    function cachedNavForOps() external view returns (uint256 nav, bool valid) {
        return _cachedNavForOps();
    }

    function _cachedNavForOps() internal view returns (uint256 nav, bool valid) {
        nav = _opsNavCache;
        valid = (block.timestamp < uint256(_opsNavCacheTs) + uint256(opsNavCacheTtl))
            && _opsNavCacheTs > 0;
    }

    function _refreshOpsNavCache() internal {
        _opsNavCache = _totalAssets();
        _opsNavCacheTs = uint64(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PREVIEW FUNCTIONS (view-only, delegate to totalAssets live)
    // ═══════════════════════════════════════════════════════════════════════════════
    // Note: preview functions use totalAssets() (live) for PPS calculation.
    // They do NOT go through modules — they are pure ERC-4626 views.
    // Fee-aware previews are implemented in the ERC4626Module if needed.

    // Inherits default ERC4626 previews which use totalAssets() live.

    // ═══════════════════════════════════════════════════════════════════════════════
    // PROCESSOR FUNCTIONS (for modules to mint/burn/transfer shares)
    // ═══════════════════════════════════════════════════════════════════════════════

    function _requireModuleAccess() internal view {
        // Pattern 1: Delegatecall context (QueueModule, AdminModule, LiquidityOpsModule)
        if (msg.sender == address(this)) return;
        // Pattern 2: Authorized external module (ERC4626Module)
        if (CoreStorage.layout().isAuthorizedModule[msg.sender]) return;
        revert NotAuthorizedModule();
    }

    function processorMint(address to, uint256 amount) external {
        _requireModuleAccess();
        _mint(to, amount);
    }

    function processorBurn(address from, uint256 amount) external {
        _requireModuleAccess();
        _burn(from, amount);
    }

    function processorTransfer(address from, address to, uint256 amount) external {
        _requireModuleAccess();
        _transfer(from, to, amount);
    }

    function processorSpendAllowance(address owner_, address spender, uint256 amount) external {
        _requireModuleAccess();
        _spendAllowance(owner_, spender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ICoreVault VIEW INTERFACE
    // ═══════════════════════════════════════════════════════════════════════════════

    function canSettle() external view returns (bool) {
        QueueStorage.Layout storage q = QueueStorage.layout();
        return q.queue.length > q.head;
    }

    function canCrystallize() external view returns (bool) {
        FeeStorage.Layout storage f = FeeStorage.layout();
        uint256 hwm = f.highWaterMark;
        uint64 last = f.lastCrystallize;
        uint64 minInterval = f.minCrystallizeInterval;

        if (hwm == 0) return true;
        if (block.timestamp < uint256(last) + uint256(minInterval)) return false;
        uint256 ts = totalSupply();
        if (ts == 0) return false;
        uint256 pps = (_totalAssets() * 1e18) / ts;
        return pps > hwm;
    }

    function canRealize() external view returns (bool) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;
        if (address(bm) == address(0)) return false;
        if (address(core.router) == address(0)) return false;

        uint16 targetBps = bm.getConfig().opsReserveTargetBps;
        if (targetBps == 0) return false;

        uint256 currentCash = IERC20(asset()).balanceOf(address(this));
        uint256 tvl = _totalAssets();
        uint256 target = Percentage.mulBpsDown(tvl, targetBps);
        return currentCash < target;
    }

    /// @notice canRealize with gap — single call for VaultUpkeep (avoids redundant totalAssets)
    /// @notice Realize assets from strategies to hot buffer (routed to LiquidityOpsModule)
    /// @dev Required by ICoreVault interface. Delegates to module via fallback-style dispatch.
    function realizeForReserveAndOps(uint256 maxAmount) external {
        bytes memory result = _delegateToModule(
            bytes4(keccak256("realizeForReserveAndOps(uint256)")),
            msg.data
        );
        _refreshOpsNavCache();
    }

    function canRealizeWithGap() external view returns (bool canR, uint256 gap) {
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;
        if (address(bm) == address(0)) return (false, 0);
        if (address(core.router) == address(0)) return (false, 0);

        uint16 targetBps = bm.getConfig().opsReserveTargetBps;
        if (targetBps == 0) return (false, 0);

        uint256 currentCash = IERC20(asset()).balanceOf(address(this));
        uint256 tvl = _totalAssets();
        uint256 target = Percentage.mulBpsDown(tvl, targetBps);
        if (currentCash >= target) return (false, 0);
        return (true, target - currentCash);
    }

    /// @notice Returns strategy redeem deficit for pending queue claims.
    /// @dev Single source of truth for VaultUpkeep scheduler.
    ///      Returns 0 if hot + warm (discounted by slippage) cover the batch.
    ///      Returns the USDC shortfall that must come from strategy redeem.
    function deficitForQueue(uint256 maxClaims) external view returns (uint256 deficit) {
        (bool ok, bytes memory data) = address(this).staticcall(
            abi.encodeWithSignature("requiredHotForBatch(uint256)", maxClaims)
        );
        if (!ok) return 0;
        uint256 required = abi.decode(data, (uint256));
        if (required == 0) return 0;

        uint256 hot = IERC20(asset()).balanceOf(address(this));
        if (hot >= required) return 0;

        // Discount warm by slippage (conservative estimate)
        CoreStorage.Layout storage core = CoreStorage.layout();
        IBufferManager bm = core.bufferManager;
        if (address(bm) != address(0)) {
            (uint256 warmNav,, bool valid) = bm.warmNavState();
            if (valid && warmNav > 0) {
                uint16 slipBps = bm.getConfig().maxWarmSlippageBps;
                uint256 usableWarm = warmNav * (10000 - uint256(slipBps)) / 10000;
                uint256 available = hot + usableWarm;
                if (available >= required) return 0;
                return required - available;
            }
        }
        return required - hot;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function lastDepositTs(address user) external view returns (uint64) {
        return CoreStorage.layout().lastDepositTs[user];
    }

    function epochStart() external view returns (uint64) {
        return CoreStorage.layout().epochStart;
    }

    function epochWithdrawn() external view returns (uint256) {
        return CoreStorage.layout().epochWithdrawn;
    }

    function paramMinDelay() external view returns (uint64) {
        return CoreStorage.layout().paramMinDelay;
    }

    function isParamsFrozen() external view returns (bool) {
        return CoreStorage.layout().packedFlags & CoreStorage.FLAG_PARAMS_FROZEN != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // WARM ADAPTER APPROVALS
    // ═══════════════════════════════════════════════════════════════════════════════

    function approveWarmAdapters(address[] calldata adapters) external onlyOwner {
        address assetAddr = asset();
        for (uint256 i; i < adapters.length;) {
            IERC20(assetAddr).forceApprove(adapters[i], type(uint256).max);
            emit Events.WarmAdapterApproved(adapters[i]);
            unchecked { ++i; }
        }
    }

    function revokeWarmAdapters(address[] calldata adapters) external onlyOwner {
        address assetAddr = asset();
        for (uint256 i; i < adapters.length;) {
            IERC20(assetAddr).forceApprove(adapters[i], 0);
            emit Events.WarmAdapterRevoked(adapters[i]);
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // REWARD SHARES MINTING (dedicated, minimal — only callable by authorized payout manager)
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Mint vault shares as incentive reward payout.
    ///         Tightly-scoped: ONLY callable by authorized RewardsPayoutManager.
    ///         NOT processorMint — this is a separate, dedicated function.
    /// @param user Recipient of reward shares
    /// @param usdcEquivalent USDC-equivalent amount (6 decimals) to convert to shares
    function mintRewardShares(address user, uint256 usdcEquivalent) external {
        CoreStorage.Layout storage core = CoreStorage.layout();
        require(msg.sender == core.rewardsPayoutManager, "not-payout-manager");
        require(user != address(0), "user=0");
        if (usdcEquivalent == 0) return;

        // Use convertToShares (no fee) — reward minting is fee-free
        uint256 shares = convertToShares(usdcEquivalent);
        if (shares == 0) return;

        _mint(user, shares);
        emit Events.RewardSharesMinted(user, usdcEquivalent, shares);
    }
}
