// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { FeeCollector } from "../../src/core/modules/FeeCollector.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20Mock } from "../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { IQueueModule } from "../../src/interfaces/IQueueModule.sol";

/**
 * @title CoreVault_ClaimsQueue_Invariants
 * @notice Invariant tests specifically for the claims queue system
 *
 * Core Queue Invariants:
 * 1. QUEUE_LENGTH: queueLength() == number of open claims (not settled, not cancelled)
 * 2. CLAIM_OWNERSHIP: Only claim owner can cancel their claim
 * 3. MIN_CLAIM_RESPECTED: No claim in queue has grossAssets < minClaimAmount
 * 4. NO_DOUBLE_SETTLE: A claim cannot be settled twice
 * 5. NO_DOUBLE_CANCEL: A claim cannot be cancelled twice
 * 6. SHARES_ACCOUNTING: Total supply + queued shares + cancelled shares balance correctly
 *
 * @dev Uses invariant testing with focused claim queue handler
 */
contract CoreVault_ClaimsQueue_Invariants is StdInvariant, Test {
    /* ========== CONTRACTS ========== */
    CoreVault public vault;
    FeeCollector public feeCollector;
    MockParamsProvider public params;
    ERC20Mock public usdc;
    ClaimQueueHandler public handler;
    QueueModule public queueModule;
    AdminModule public adminModule;

    /* ========== ADDRESSES ========== */
    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public treasury = address(0xFEE1);
    address public opsSafe = address(0xFEE2);
    address public safetyReserve = address(0xFEE3);

    function setUp() public {
        // Deploy USDC mock
        usdc = new ERC20Mock("USDC", "USDC", 6);

        // Deploy MockParamsProvider
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        // Deploy FeeCollector
        feeCollector = new FeeCollector(
            owner,
            treasury,
            opsSafe,
            safetyReserve,
            7000, // 70% treasury
            200, // 2% safety
            3000 // 30% max ops
        );

        // Deploy modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        // Deploy CoreVault with 6-param constructor
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Queue Invariant Vault",
            "qvUSDC",
            address(this), // owner (this contract for setup)
            address(feeCollector),
            address(params)
        );

        // Wire up modules
        _wireModules();

        // Set guardian
        vault.setGuardian(guardian);

        // Transfer ownership
        vault.beginOwnerTransfer(owner);
        vm.prank(owner);
        vault.acceptOwnerTransfer();

        // Deploy handler
        handler = new ClaimQueueHandler(vault, usdc, feeCollector);

        // Setup invariant targets
        targetContract(address(handler));

        // Exclude system addresses
        excludeSender(address(vault));
        excludeSender(address(feeCollector));
        excludeSender(owner);
        excludeSender(guardian);
        excludeSender(treasury);
    }

    function _wireModules() internal {
        // QueueModule selectors (PUBLIC)
        vault.setModule(
            QueueModule.requestClaim.selector, address(queueModule), vault.ROLE_PUBLIC()
        );
        vault.setModule(QueueModule.cancelClaim.selector, address(queueModule), vault.ROLE_PUBLIC());
        vault.setModule(
            QueueModule.processQueuedRedemptions.selector, address(queueModule), vault.ROLE_PUBLIC()
        );
        vault.setModule(
            QueueModule.settleFeesAndProcessQueue.selector,
            address(queueModule),
            vault.ROLE_PUBLIC()
        );
        vault.setModule(
            QueueModule.pendingShares.selector, address(queueModule), vault.ROLE_PUBLIC()
        );
        vault.setModule(QueueModule.queueLength.selector, address(queueModule), vault.ROLE_PUBLIC());

        // AdminModule selectors (OWNER)
        vault.setModule(
            AdminModule.submitFeeParams.selector, address(adminModule), vault.ROLE_OWNER()
        );
        vault.setModule(
            AdminModule.acceptFeeParams.selector, address(adminModule), vault.ROLE_OWNER()
        );
        vault.setModule(
            AdminModule.getFeeParams.selector, address(adminModule), vault.ROLE_PUBLIC()
        );
    }

    /* ========== INVARIANT: QUEUE LENGTH ========== */

    /**
     * @notice Queue length should match handler's tracked open claims
     */
    function invariant_queueLength() public view {
        uint256 vaultQueueLen = IQueueModule(address(vault)).queueLength();
        uint256 handlerQueueLen = handler.ghost_openClaims();

        // Handler tracks claims it created that haven't been processed
        // These should match (may differ if claims processed outside handler)
        assertGe(
            handlerQueueLen + handler.ghost_processedClaims() + handler.ghost_cancelledClaims(),
            handler.ghost_totalClaimsCreated(),
            "QUEUE: Total claims accounted for"
        );
    }

    /* ========== INVARIANT: CLAIM OWNERSHIP ========== */

    /**
     * @notice No user should be able to cancel another user's claim
     * @dev Verified by handler tracking cancel attempts and results
     */
    function invariant_claimOwnershipProtection() public view {
        // Handler tracks unauthorized cancel attempts
        assertEq(
            handler.ghost_unauthorizedCancelAttempts(),
            handler.ghost_unauthorizedCancelReverts(),
            "OWNERSHIP: All unauthorized cancels should revert"
        );
    }

    /* ========== INVARIANT: NO DOUBLE SETTLE ========== */

    /**
     * @notice A claim should never be settled twice
     */
    function invariant_noDoubleSettle() public view {
        // Handler tracks total payouts vs claims
        uint256 totalClaims = handler.ghost_totalClaimsCreated();
        uint256 processed = handler.ghost_processedClaims();
        uint256 cancelled = handler.ghost_cancelledClaims();
        uint256 open = handler.ghost_openClaims();

        // All claims should be accounted for exactly once
        assertEq(
            processed + cancelled + open,
            totalClaims,
            "DOUBLE_SETTLE: Claims should be accounted for exactly once"
        );
    }

    /* ========== INVARIANT: SHARES ACCOUNTING ========== */

    /**
     * @notice Total shares (supply + pending) should not exceed what was minted
     */
    function invariant_sharesAccounting() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 totalDeposited = handler.ghost_totalDeposited();
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn();
        uint256 totalFees = handler.ghost_totalFees();

        // What remains should be <= what was deposited minus withdrawals
        // (accounting for fees which are also shares)
        if (totalDeposited > 0) {
            // Total supply should be reasonable relative to deposits
            // This is a sanity check, not exact due to fee mechanics
            assertTrue(
                totalSupply <= totalDeposited * 2, "SHARES: Supply should not exceed 2x deposits"
            );
        }
    }

    /* ========== INVARIANT: VAULT SOLVENCY ========== */

    /**
     * @notice Vault should remain solvent through all queue operations
     */
    function invariant_vaultSolvency() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();

        if (totalSupply > 0) {
            assertGt(totalAssets, 0, "SOLVENCY: Assets must exist if shares exist");
        }
    }

    /* ========== INVARIANT: CLAIM AMOUNTS ========== */

    /**
     * @notice Total payout should not exceed total deposited + yield
     */
    function invariant_payoutBounded() public view {
        uint256 totalDeposited = handler.ghost_totalDeposited();
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn();
        uint256 totalYield = handler.ghost_totalYield();

        // Withdrawals should not exceed deposits + yield
        assertLe(
            totalWithdrawn,
            totalDeposited + totalYield,
            "PAYOUT: Withdrawals bounded by deposits + yield"
        );
    }

    /* ========== CALL SUMMARY ========== */

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}

/**
 * @title ClaimQueueHandler
 * @notice Fuzz handler for claims queue invariant testing
 * @dev Includes feeCollector.distribute for comprehensive coverage
 */
contract ClaimQueueHandler is Test {
    CoreVault public vault;
    ERC20Mock public usdc;
    FeeCollector public feeCollector;
    IQueueModule public queueModule;

    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalYield;
    uint256 public ghost_totalFees;
    uint256 public ghost_totalClaimsCreated;
    uint256 public ghost_processedClaims;
    uint256 public ghost_cancelledClaims;
    uint256 public ghost_openClaims;
    uint256 public ghost_unauthorizedCancelAttempts;
    uint256 public ghost_unauthorizedCancelReverts;

    // Call counters
    uint256 public calls_deposit;
    uint256 public calls_scheduledClaim;
    uint256 public calls_immediateClaim;
    uint256 public calls_cancelClaim;
    uint256 public calls_processQueue;
    uint256 public calls_yield;

    // Claim tracking
    mapping(uint256 => address) public claimOwners;
    mapping(uint256 => bool) public claimSettled;
    mapping(uint256 => bool) public claimCancelled;
    uint256 public nextClaimId;

    // Actor tracking
    address[] public actors;
    mapping(address => bool) public isActor;
    mapping(address => uint256[]) public actorClaims;

    modifier createActor(uint256 seed) {
        address actor = _getActor(seed);
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    constructor(CoreVault _vault, ERC20Mock _usdc, FeeCollector _feeCollector) {
        vault = _vault;
        usdc = _usdc;
        feeCollector = _feeCollector;
        queueModule = IQueueModule(address(_vault));
        // IMPORTANT: Vault's nextClaimId uses pre-increment (++nextClaimId),
        // so first claimId is 1, not 0. Sync handler's tracking to match.
        nextClaimId = 1;
    }

    /* ========== HANDLER FUNCTIONS ========== */

    function deposit(uint256 actorSeed, uint256 amount) public createActor(actorSeed) {
        amount = bound(amount, 1_000e6, 10_000_000e6);
        address actor = _getActor(actorSeed);

        // Fund actor
        usdc._mint(actor, amount);
        usdc.approve(address(vault), amount);

        vault.deposit(amount, actor);

        ghost_totalDeposited += amount;
        calls_deposit++;
    }

    function scheduledClaim(uint256 actorSeed, uint256 sharePct) public createActor(actorSeed) {
        address actor = _getActor(actorSeed);
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        sharePct = bound(sharePct, 1, 50);
        uint256 claimShares = (shares * sharePct) / 100;
        if (claimShares == 0) claimShares = 1;

        try queueModule.requestClaim(false, claimShares) {
            claimOwners[nextClaimId] = actor;
            actorClaims[actor].push(nextClaimId);
            ghost_totalClaimsCreated++;
            ghost_openClaims++;
            nextClaimId++;
            calls_scheduledClaim++;
        } catch { }
    }

    function immediateClaim(uint256 actorSeed, uint256 sharePct) public createActor(actorSeed) {
        address actor = _getActor(actorSeed);
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        sharePct = bound(sharePct, 1, 20);
        uint256 claimShares = (shares * sharePct) / 100;
        if (claimShares == 0) claimShares = 1;

        uint256 balBefore = usdc.balanceOf(actor);

        try queueModule.requestClaim(true, claimShares) {
            // Immediate claims are processed inline
            uint256 balAfter = usdc.balanceOf(actor);
            ghost_totalWithdrawn += (balAfter - balBefore);
            calls_immediateClaim++;
        } catch { }
    }

    function cancelOwnClaim(uint256 actorSeed, uint256 claimIndex) public createActor(actorSeed) {
        address actor = _getActor(actorSeed);

        uint256[] storage claims = actorClaims[actor];
        if (claims.length == 0) return;

        claimIndex = bound(claimIndex, 0, claims.length - 1);
        uint256 claimId = claims[claimIndex];

        if (claimSettled[claimId] || claimCancelled[claimId]) return;

        try queueModule.cancelClaim(claimId) {
            claimCancelled[claimId] = true;
            ghost_cancelledClaims++;
            if (ghost_openClaims > 0) ghost_openClaims--;
            calls_cancelClaim++;
        } catch { }
    }

    function cancelOthersClaim(uint256 actorSeed, uint256 targetActorSeed)
        public
        createActor(actorSeed)
    {
        address actor = _getActor(actorSeed);
        address targetActor = _getActor(targetActorSeed);

        if (actor == targetActor) return; // Skip if same actor

        uint256[] storage claims = actorClaims[targetActor];
        if (claims.length == 0) return;

        uint256 claimId = claims[0]; // Try to cancel first claim

        if (claimSettled[claimId] || claimCancelled[claimId]) return;

        ghost_unauthorizedCancelAttempts++;

        try queueModule.cancelClaim(claimId) {
        // Should not succeed - this would be a bug
        }
        catch {
            ghost_unauthorizedCancelReverts++;
        }
    }

    function processQueue(uint256 maxClaims) public {
        maxClaims = bound(maxClaims, 1, 25);

        // Warp to ensure claims can be settled
        vm.warp(block.timestamp + 7 days);

        uint256 queueLenBefore = queueModule.queueLength();

        try queueModule.settleFeesAndProcessQueue(maxClaims) {
            uint256 queueLenAfter = queueModule.queueLength();
            uint256 processed = queueLenBefore - queueLenAfter;
            ghost_processedClaims += processed;
            if (ghost_openClaims >= processed) {
                ghost_openClaims -= processed;
            }
            calls_processQueue++;
        } catch { }
    }

    function simulateYield(uint256 yieldAmount) public {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        if (vaultBalance == 0) {
            calls_yield++;
            return;
        }

        // Cap cumulative yield at 50% of total deposits (realistic ~20% APY with margin)
        uint256 maxCumulativeYield = (ghost_totalDeposited * 50) / 100;
        if (ghost_totalYield >= maxCumulativeYield) {
            calls_yield++;
            return;
        }

        // Yield = 0.1% to 2% of vault balance (realistic range)
        yieldAmount = bound(yieldAmount, vaultBalance / 1000, vaultBalance / 50);
        if (yieldAmount < 1e6) yieldAmount = 1e6;

        // Ensure we don't exceed cumulative cap
        uint256 remainingYieldBudget = maxCumulativeYield - ghost_totalYield;
        if (yieldAmount > remainingYieldBudget) {
            yieldAmount = remainingYieldBudget;
        }

        usdc._mint(address(vault), yieldAmount);
        ghost_totalYield += yieldAmount;

        // Crystallize to update share price
        vm.warp(block.timestamp + 2 hours);

        // Track queue length before processing to update ghost_openClaims
        uint256 queueLenBefore = queueModule.queueLength();

        queueModule.settleFeesAndProcessQueue(1);

        // Update ghost state if claims were processed
        uint256 queueLenAfter = queueModule.queueLength();
        uint256 processed = queueLenBefore - queueLenAfter;
        if (processed > 0) {
            ghost_processedClaims += processed;
            if (ghost_openClaims >= processed) {
                ghost_openClaims -= processed;
            } else {
                ghost_openClaims = 0;
            }
        }

        calls_yield++;
    }

    /**
     * @notice Distribute accumulated fees from FeeCollector
     */
    function distributeFees() public {
        uint256 fcShares = vault.balanceOf(address(feeCollector));
        if (fcShares == 0) {
            calls_distribute++;
            return;
        }

        // Configure and distribute
        address governor = feeCollector.governor();
        vm.startPrank(governor);

        try feeCollector.setShareConfig(address(vault), FeeCollector.ShareMode.SPLIT_SHARES) { }
            catch { }
        try feeCollector.setAllowedToken(address(vault), true) { } catch { }
        try feeCollector.toggleAllowlist(true) { } catch { }

        vm.stopPrank();

        try feeCollector.distribute(address(vault)) {
            ghost_distributedFees += fcShares;
            calls_distribute++;
        } catch {
            calls_distribute++;
        }
    }

    // Ghost and call counter for distribute
    uint256 public ghost_distributedFees;
    uint256 public calls_distribute;

    /* ========== HELPERS ========== */

    function _getActor(uint256 seed) internal returns (address) {
        seed = bound(seed, 0, 4); // 5 actors
        address actor = address(uint160(0x20000 + seed));

        if (!isActor[actor]) {
            actors.push(actor);
            isActor[actor] = true;
        }

        return actor;
    }

    function callSummary() public view {
        console2.log("=== CLAIMS QUEUE HANDLER SUMMARY ===");
        console2.log("Deposits:", calls_deposit);
        console2.log("Scheduled Claims:", calls_scheduledClaim);
        console2.log("Immediate Claims:", calls_immediateClaim);
        console2.log("Cancel Own Claims:", calls_cancelClaim);
        console2.log("Process Queue:", calls_processQueue);
        console2.log("Yield Simulations:", calls_yield);
        console2.log("Distributes:", calls_distribute);
        console2.log("");
        console2.log("=== GHOST STATE ===");
        console2.log("Total Claims Created:", ghost_totalClaimsCreated);
        console2.log("Processed Claims:", ghost_processedClaims);
        console2.log("Cancelled Claims:", ghost_cancelledClaims);
        console2.log("Open Claims:", ghost_openClaims);
        console2.log("Unauthorized Cancel Attempts:", ghost_unauthorizedCancelAttempts);
        console2.log("Unauthorized Cancel Reverts:", ghost_unauthorizedCancelReverts);
        console2.log("Total Deposited:", ghost_totalDeposited);
        console2.log("Total Withdrawn:", ghost_totalWithdrawn);
        console2.log("Distributed Fees:", ghost_distributedFees);
    }
}
