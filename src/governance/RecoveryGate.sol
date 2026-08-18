// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CoreVault } from "../core/CoreVault.sol";
import { SelectorLib } from "../core/libraries/SelectorLib.sol";

/**
 * @title RecoveryGate
 * @notice Emergency Module Recovery — the narrow, immutable alternative to
 *         generic post-seal upgradeability approved by the architecture
 *         review (Multyr Core Upgradeability, Emergency Recovery & Incident
 *         Response Architecture Review, snapshot 0bab749, §§5-14).
 *
 * WHAT THIS IS NOT:
 *      Not a general-purpose upgrade mechanism. Not callable by anyone but
 *      ROOT_TIMELOCK to propose, SECURITY_APPROVER to approve, and CoreVault's
 *      own vetoer to cancel. Cannot add selectors, cannot relax roles, cannot
 *      touch CoreVault's shell, governance, or this contract's own policy.
 *
 * WHAT THIS IS:
 *      A dedicated, separate entry point (review §7) that lets ROOT_TIMELOCK
 *      replace the module implementation behind one of four pre-approved,
 *      economically-isolated selector groups (review §9), after an immutable
 *      minimum delay (review §12), independent security approval bound to an
 *      exact digest (review §13), and subject to cancellation by CoreVault's
 *      vetoer at any point before execution (review §14).
 *
 * RECOVERABLE GROUPS (review §9 — economically isolated execution modules).
 * Two different reasons keep everything else permanently out of scope:
 *   - AdminModule's governance/sealing/authorization selectors ARE
 *     moduleOf-routed (same dispatcher as every recoverable group), but no
 *     group here enumerates them — exclusion is definitional (a fixed,
 *     closed whitelist), not structural. A fifth group could theoretically
 *     be added in a future contract; this one has none.
 *   - CoreVault's own direct functions (setModule*, freezeRouting, pause*,
 *     setSelectorRegistry, authorizeModule, etc.) are NOT moduleOf-routed at
 *     all — there is no selector for recoverModuleGroup() to touch them
 *     with, regardless of group ID. This exclusion IS structural.
 *      0 = EPOCH_QUEUE_GROUP     — EpochedQueueModule (write + view selectors)
 *      1 = ERC4626_GROUP         — ERC4626Module
 *      2 = LIQUIDITY_GROUP       — LiquidityOpsModule
 *      3 = FIXED_MATURITY_GROUP  — FixedMaturityModule
 * Selector sets are read directly from SelectorLib — the same source of
 * truth CoreVault's own deployment wiring uses — so there is no second,
 * independently-maintained selector registry to drift out of sync.
 *
 * IMMUTABLE RECOVERY POLICY (review §8 — fixed at construction, no setters
 * of any kind on delay, cooldown, vault, or root timelock):
 *      - minDelay: hard floor of 14 days, enforced in the constructor itself
 *        (a misconfigured deployment cannot even be deployed with less).
 *      - cooldown: minimum gap between two completed recoveries of the same
 *        group, preventing a group from being salami-sliced through
 *        repeated recoveries that each individually pass review but
 *        cumulatively amount to continuous evolution.
 *      - securityApprover is the one field that IS rotatable — but only by
 *        ROOT_TIMELOCK, and only subject to the same minDelay as a recovery
 *        itself, so a compromised timelock cannot fast-track a friendly
 *        approver into place in time to matter. This resolves the open
 *        question raised in docs/developer-response-recovery-architecture
 *        §6 in favor of rotatability over permanent key-loss risk.
 *
 * CAVEAT (review §4): restricting recovery to existing selectors, unchanged
 * roles, and pre-approved groups does not mathematically prove a replacement
 * module only repairs a bug — a delegatecall-executed module can still alter
 * economic behavior while using identical selectors and roles. This contract
 * enforces the procedural restrictions; it is not cryptographic proof of
 * semantic equivalence. See docs/recovery.md.
 */
contract RecoveryGate {
    // ═══════════════════════════════════════════════════════════════════════════════
    // GROUP IDS
    // ═══════════════════════════════════════════════════════════════════════════════
    uint8 public constant EPOCH_QUEUE_GROUP = 0;
    uint8 public constant ERC4626_GROUP = 1;
    uint8 public constant LIQUIDITY_GROUP = 2;
    uint8 public constant FIXED_MATURITY_GROUP = 3;
    uint8 public constant GROUP_COUNT = 4;

    /// @dev Committed into every proposal digest so an approval can never be
    ///      replayed against a policy the approver did not actually review.
    uint256 public constant MANIFEST_VERSION = 1;

    /// @dev Matches the execution-grace-window idiom already used by
    ///      TimelockLib/AdminModule elsewhere in this codebase: a proposal
    ///      that becomes executable but is never executed expires rather
    ///      than remaining eternally executable.
    uint64 public constant EXECUTION_WINDOW = 7 days;

    // ═══════════════════════════════════════════════════════════════════════════════
    // IMMUTABLE POLICY
    // ═══════════════════════════════════════════════════════════════════════════════
    address public immutable vault;
    address public immutable rootTimelock;
    uint64 public immutable minDelay;
    uint64 public immutable cooldown;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════════
    address public securityApprover;

    struct Proposal {
        bytes32 digest;
        uint64 eta;
        bool approved;
        bool exists;
        address[] newModules;
    }

    mapping(uint8 => Proposal) public proposals;
    mapping(uint8 => uint64) public lastRecoveryCompletedAt;

    struct PendingApprover {
        address newApprover;
        uint64 eta;
        bool exists;
    }

    PendingApprover public pendingApprover;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════
    error DelayTooShort();
    error ZeroAddress();
    error InvalidGroup();
    error NotRootTimelock();
    error NotSecurityApprover();
    error NotVetoer();
    error WrongSelectorCount();
    error PendingProposalExists();
    error NoPendingProposal();
    error DigestMismatch();
    error EtaNotReached();
    error EtaExpired();
    error NotApproved();
    error CooldownActive();

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════
    event RecoveryProposed(uint8 indexed groupId, bytes32 digest, uint64 eta, bytes32 reasonRef);
    event RecoveryApproved(uint8 indexed groupId, bytes32 digest);
    event RecoveryVetoed(uint8 indexed groupId, bytes32 digest);
    event RecoveryExecuted(uint8 indexed groupId, bytes32 digest, address[] newModules);
    event ApproverChangeProposed(address indexed newApprover, uint64 eta);
    event ApproverChangeExecuted(address indexed newApprover);
    event ApproverChangeVetoed(address indexed newApprover);

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @param _minDelay Minimum recovery delay. Reverts if under 14 days —
    ///        review §12's recommended floor, enforced structurally rather
    ///        than by policy so a misconfigured deployment cannot exist.
    constructor(
        address _vault,
        address _rootTimelock,
        address _securityApprover,
        uint64 _minDelay,
        uint64 _cooldown
    ) {
        if (_vault == address(0) || _rootTimelock == address(0) || _securityApprover == address(0)) {
            revert ZeroAddress();
        }
        if (_minDelay < 14 days) revert DelayTooShort();

        vault = _vault;
        rootTimelock = _rootTimelock;
        securityApprover = _securityApprover;
        minDelay = _minDelay;
        cooldown = _cooldown;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyRootTimelock() {
        if (msg.sender != rootTimelock) revert NotRootTimelock();
        _;
    }

    modifier onlySecurityApprover() {
        if (msg.sender != securityApprover) revert NotSecurityApprover();
        _;
    }

    /// @dev Reads CoreVault.vetoer() live on every call rather than caching
    ///      it — CoreVault is the single source of truth for who the vetoer
    ///      is, so this can never drift from it.
    modifier onlyVetoer() {
        if (msg.sender != CoreVault(payable(vault)).vetoer()) revert NotVetoer();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // RECOVERY LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Propose replacing the module backing every selector in
    ///         `groupId` with `newModules` (one address per selector, same
    ///         order as `_selectorsForGroup`). Only ROOT_TIMELOCK — schedule
    ///         this through the timelock's own delay exactly as
    ///         SystemSealer.verifyAndSeal() is scheduled; this contract's
    ///         minDelay clock then runs on top of, not instead of, that.
    function propose(uint8 groupId, address[] calldata newModules, bytes32 reasonRef)
        external
        onlyRootTimelock
    {
        bytes4[] memory selectors = _selectorsForGroup(groupId);
        if (newModules.length != selectors.length) revert WrongSelectorCount();

        Proposal storage p = proposals[groupId];
        if (p.exists && !_isExpired(p)) revert PendingProposalExists();

        if (
            lastRecoveryCompletedAt[groupId] != 0
                && block.timestamp < uint256(lastRecoveryCompletedAt[groupId]) + cooldown
        ) {
            revert CooldownActive();
        }

        bytes32 digest = _computeDigest(groupId, selectors, newModules, reasonRef);
        uint64 eta = uint64(block.timestamp) + minDelay;

        p.digest = digest;
        p.eta = eta;
        p.approved = false;
        p.exists = true;
        p.newModules = newModules;

        emit RecoveryProposed(groupId, digest, eta, reasonRef);
    }

    /// @notice Approve the currently pending proposal for `groupId`. Must be
    ///         called with the exact digest being approved — if `propose()`
    ///         is called again for the same group before this executes, the
    ///         digest changes and this approval is silently invalidated
    ///         (review §13: "any modification invalidates previous
    ///         approval").
    function approve(uint8 groupId, bytes32 digest) external onlySecurityApprover {
        Proposal storage p = proposals[groupId];
        if (!p.exists || _isExpired(p)) revert NoPendingProposal();
        if (p.digest != digest) revert DigestMismatch();

        p.approved = true;
        emit RecoveryApproved(groupId, digest);
    }

    /// @notice Cancel the pending proposal for `groupId`. Cancellation-only —
    ///         the vetoer has no other capability on this contract, so it
    ///         structurally cannot propose, approve, or execute (review §14).
    function vetoCancel(uint8 groupId) external onlyVetoer {
        Proposal storage p = proposals[groupId];
        if (!p.exists) revert NoPendingProposal();

        bytes32 digest = p.digest;
        delete proposals[groupId];
        emit RecoveryVetoed(groupId, digest);
    }

    /// @notice Execute an approved, matured, non-vetoed proposal. Open
    ///         caller — mirrors acceptRouter()/acceptFeeParams() already
    ///         being open in AdminModule once their own conditions are met.
    function execute(uint8 groupId) external {
        Proposal storage p = proposals[groupId];
        if (!p.exists) revert NoPendingProposal();
        if (block.timestamp < p.eta) revert EtaNotReached();
        if (block.timestamp > uint256(p.eta) + EXECUTION_WINDOW) revert EtaExpired();
        if (!p.approved) revert NotApproved();

        bytes32 digest = p.digest;
        address[] memory newModules = p.newModules;

        delete proposals[groupId];
        lastRecoveryCompletedAt[groupId] = uint64(block.timestamp);

        CoreVault(payable(vault)).recoverModuleGroup(groupId, newModules);

        emit RecoveryExecuted(groupId, digest, newModules);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECURITY APPROVER ROTATION
    // ═══════════════════════════════════════════════════════════════════════════════
    // The one rotatable field in an otherwise immutable policy (see contract
    // NatSpec). Subject to the same minDelay and the same vetoer as a
    // recovery itself, so compromising ROOT_TIMELOCK cannot install a
    // friendly approver in time to matter for any recovery already in flight.

    function proposeApproverChange(address newApprover) external onlyRootTimelock {
        if (newApprover == address(0)) revert ZeroAddress();
        if (pendingApprover.exists && !_isApproverChangeExpired()) revert PendingProposalExists();

        uint64 eta = uint64(block.timestamp) + minDelay;
        pendingApprover = PendingApprover({ newApprover: newApprover, eta: eta, exists: true });

        emit ApproverChangeProposed(newApprover, eta);
    }

    function executeApproverChange() external {
        if (!pendingApprover.exists) revert NoPendingProposal();
        if (block.timestamp < pendingApprover.eta) revert EtaNotReached();
        if (block.timestamp > uint256(pendingApprover.eta) + EXECUTION_WINDOW) revert EtaExpired();

        address newApprover = pendingApprover.newApprover;
        delete pendingApprover;
        securityApprover = newApprover;

        emit ApproverChangeExecuted(newApprover);
    }

    function vetoApproverChange() external onlyVetoer {
        if (!pendingApprover.exists) revert NoPendingProposal();
        address rejected = pendingApprover.newApprover;
        delete pendingApprover;
        emit ApproverChangeVetoed(rejected);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice The exact selector set a given group covers, in the same
    ///         order `propose()`/`execute()` expect `newModules` to match.
    ///         Sourced directly from SelectorLib — no second registry.
    function selectorsForGroup(uint8 groupId) external pure returns (bytes4[] memory) {
        return _selectorsForGroup(groupId);
    }

    function pendingProposal(uint8 groupId)
        external
        view
        returns (bytes32 digest, uint64 eta, bool approved, bool exists)
    {
        Proposal storage p = proposals[groupId];
        return (p.digest, p.eta, p.approved, p.exists);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════════

    function _isExpired(Proposal storage p) internal view returns (bool) {
        return block.timestamp > uint256(p.eta) + EXECUTION_WINDOW;
    }

    function _isApproverChangeExpired() internal view returns (bool) {
        return block.timestamp > uint256(pendingApprover.eta) + EXECUTION_WINDOW;
    }

    function _selectorsForGroup(uint8 groupId) internal pure returns (bytes4[] memory) {
        if (groupId == EPOCH_QUEUE_GROUP) {
            return _concat(SelectorLib.getQueueModuleSelectors(), SelectorLib.getQueueModuleViewSelectors());
        }
        if (groupId == ERC4626_GROUP) {
            return SelectorLib.getERC4626ModuleSelectors();
        }
        if (groupId == LIQUIDITY_GROUP) {
            return SelectorLib.getLiquidityOpsModuleSelectors();
        }
        if (groupId == FIXED_MATURITY_GROUP) {
            return SelectorLib.getFixedMaturityModuleSelectors();
        }
        revert InvalidGroup();
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) out[i] = a[i];
        for (uint256 i; i < b.length; ++i) out[a.length + i] = b[i];
    }

    /// @dev Digest fields per review §13: vault, chain ID, module group,
    ///      selector set, current implementation codehash, proposed
    ///      implementation address + codehash, manifest version,
    ///      reason/reference identifier. "Unchanged role mapping" is not a
    ///      digest field because it is structurally impossible for a
    ///      recovery to change roles at all — recoverModuleGroup() never
    ///      writes roleOf (see CoreVault.sol), so there is nothing here that
    ///      could vary.
    function _computeDigest(
        uint8 groupId,
        bytes4[] memory selectors,
        address[] calldata newModules,
        bytes32 reasonRef
    ) internal view returns (bytes32) {
        CoreVault v = CoreVault(payable(vault));
        uint256 len = selectors.length;

        address[] memory currentModules = new address[](len);
        bytes32[] memory currentCodehashes = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            address cur = v.moduleOf(selectors[i]);
            currentModules[i] = cur;
            currentCodehashes[i] = cur.codehash;
        }

        bytes32[] memory newCodehashes = new bytes32[](newModules.length);
        for (uint256 i; i < newModules.length; ++i) {
            newCodehashes[i] = newModules[i].codehash;
        }

        return keccak256(
            abi.encode(
                vault,
                block.chainid,
                groupId,
                selectors,
                currentModules,
                currentCodehashes,
                newModules,
                newCodehashes,
                MANIFEST_VERSION,
                reasonRef
            )
        );
    }
}
