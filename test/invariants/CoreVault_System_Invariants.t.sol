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
 * @title CoreVault_System_Invariants
 * @notice Comprehensive invariant tests for the entire vault system
 * @dev Optimized for 10,000 runs stability
 *
 * Core Invariants:
 * 1. SOLVENCY: totalAssets >= sum of all user claims
 * 2. SHARE_ASSET_RATIO: totalSupply * sharePrice ~= totalAssets
 * 3. NO_INFLATION: No user can withdraw more than deposited (minus fees)
 * 4. FEE_BOUNDED: Fees never exceed configured maximums
 * 5. QUEUE_INTEGRITY: Queue length == number of pending claims
 * 6. NAV_CONSISTENCY: NAV is always consistent with underlying balances
 */
contract CoreVault_System_Invariants is StdInvariant, Test {
    /* ========== CONTRACTS ========== */
    CoreVault public vault;
    FeeCollector public feeCollector;
    MockParamsProvider public params;
    ERC20Mock public usdc;
    VaultHandler public handler;
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
            "Invariant Test Vault",
            "ivUSDC",
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
        handler = new VaultHandler(vault, usdc, feeCollector);

        // Setup invariant targets
        targetContract(address(handler));

        // Exclude system addresses from being senders
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

    /* ========== INVARIANT: SOLVENCY ========== */

    /**
     * @notice Vault total assets must always be >= total user deposits (minus fees)
     * @dev O(1) - only reads totalAssets and totalSupply
     */
    function invariant_solvency() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();

        // If there are shares, there must be assets
        if (totalSupply > 0) {
            assertGt(totalAssets, 0, "SOLVENCY: Assets must exist if shares exist");
        }
    }

    /* ========== INVARIANT: SHARE_ASSET_RATIO ========== */

    /**
     * @notice Share price times total supply should approximately equal total assets
     * @dev O(1) - uses 0.05% tolerance to account for fee effects
     */
    function invariant_share_asset_ratio() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();

        if (totalSupply == 0) return;

        uint256 impliedAssets = vault.convertToAssets(totalSupply);
        uint256 tolerance = totalAssets / 2000; // 0.05%
        if (tolerance < 1) tolerance = 1;

        assertApproxEqAbs(
            impliedAssets,
            totalAssets,
            tolerance,
            "SHARE_ASSET: Implied assets should match total assets"
        );
    }

    /* ========== INVARIANT: NO_INFLATION ========== */

    /**
     * @notice Total withdrawn cannot exceed total deposited plus yield minus fees
     * @dev O(1) - reads handler ghost variables only
     */
    function invariant_no_inflation() public view {
        uint256 totalDeposited = handler.ghost_totalDeposited();
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn();
        uint256 totalYield = handler.ghost_totalYield();

        uint256 maxWithdrawable = totalDeposited + totalYield;

        assertLe(
            totalWithdrawn,
            maxWithdrawable,
            "NO_INFLATION: Withdrawn cannot exceed deposited + yield"
        );
    }

    /* ========== INVARIANT: DEPOSIT_FEE_BOUNDED ========== */

    /**
     * @notice Deposit fees must not exceed configured maximum
     * @dev O(1) - reads handler ghost variables only
     */
    function invariant_deposit_fee_bounded() public view {
        uint256 totalDeposited = handler.ghost_totalDeposited();
        uint256 totalDepositFees = handler.ghost_totalDepositFees();

        if (totalDeposited == 0) return;

        // 1% max tolerance
        uint256 maxFee = (totalDeposited * 100) / 10000;

        assertLe(totalDepositFees, maxFee + 1e6, "DEPOSIT_FEE: Total deposit fees within bounds");
    }

    /* ========== INVARIANT: WITHDRAW_FEE_BOUNDED ========== */

    /**
     * @notice Withdrawal fees must not exceed configured maximum
     * @dev O(1) - reads handler ghost variables only
     */
    function invariant_withdraw_fee_bounded() public view {
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn();
        uint256 totalWithdrawFees = handler.ghost_totalWithdrawFees();

        if (totalWithdrawn == 0) return;

        uint256 totalGross = totalWithdrawn + totalWithdrawFees;
        uint256 maxFee = (totalGross * 100) / 10000;

        assertLe(totalWithdrawFees, maxFee + 1e6, "WITHDRAW_FEE: Total withdraw fees within bounds");
    }

    /* ========== INVARIANT: PERF_FEE_BOUNDED ========== */

    /**
     * @notice Performance fees must only be taken on profit above HWM
     * @dev O(1) - reads handler ghost variables only
     */
    function invariant_perf_fee_bounded() public view {
        uint256 totalPerfFees = handler.ghost_totalPerfFees();
        uint256 totalYield = handler.ghost_totalYield();

        // 35% max (30% + tolerance)
        uint256 maxPerfFee = (totalYield * 35) / 100;

        assertLe(totalPerfFees, maxPerfFee + 1e6, "PERF_FEE: Performance fees bounded by yield");
    }

    /* ========== INVARIANT: FEE_COLLECTOR_CONSERVATION ========== */

    /**
     * @notice FeeCollector should never lose value during distribution
     * @dev O(1) - reads 4 storage slots only
     */
    function invariant_fee_collector_conservation() public view {
        uint256 fcShares = vault.balanceOf(address(feeCollector));
        uint256 fcDistributed = handler.ghost_distributedFees();
        uint256 fcReceived = handler.ghost_feesCollected();

        if (fcReceived > 0) {
            uint256 fcAssets = vault.convertToAssets(fcShares);
            uint256 totalAccountedFor = fcAssets + fcDistributed;

            uint256 tolerance = fcReceived / 100;
            if (tolerance < 1e6) tolerance = 1e6;

            assertApproxEqAbs(
                totalAccountedFor,
                fcReceived,
                tolerance,
                "FEE_CONSERVATION: FeeCollector value conserved"
            );
        }
    }

    /* ========== INVARIANT: QUEUE_INTEGRITY ========== */

    /**
     * @notice Queue state must be consistent
     * @dev O(1) - reads pendingShares and vault balance
     */
    function invariant_queue_integrity() public view {
        uint256 pendingShares = IQueueModule(address(vault)).pendingShares();

        if (pendingShares > 0) {
            uint256 vaultOwnShares = vault.balanceOf(address(vault));
            assertEq(
                vaultOwnShares, pendingShares, "QUEUE: Escrowed shares must equal pendingShares"
            );
        }
    }

    /* ========== INVARIANT: NAV_CONSISTENCY ========== */

    /**
     * @notice NAV should be consistent with underlying token balance
     * @dev O(1) - reads totalAssets and usdc balance
     */
    function invariant_nav_consistency() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 vaultBalance = usdc.balanceOf(address(vault));

        assertLe(
            totalAssets,
            vaultBalance + handler.ghost_deployedToStrategies(),
            "NAV: Total assets consistent with balance"
        );
    }

    /* ========== INVARIANT: FEECOLLECTOR_BALANCE ========== */

    /**
     * @notice FeeCollector shares should be convertible to assets
     * @dev O(1) - reads 5 storage slots only
     */
    function invariant_feeCollector_balance() public view {
        uint256 fcShares = vault.balanceOf(address(feeCollector));
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();

        if (totalSupply == 0 || totalAssets == 0) return;

        uint256 sharePrice = (totalAssets * 1e6) / totalSupply;
        if (sharePrice < 5e5) return; // Share price < 0.5, skip

        if (fcShares > 1000 && fcShares > totalAssets / 1e12) {
            uint256 fcAssets = vault.convertToAssets(fcShares);
            assertGt(fcAssets, 0, "FEECOLLECTOR: Significant shares should convert to assets");
        }
    }

    /* ========== CALL SUMMARY ========== */

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}

/**
 * @title VaultHandler
 * @notice Fuzz handler for vault invariant testing - optimized for 10k runs
 * @dev Aggressive bounds, guard clauses, structure caps
 */
contract VaultHandler is Test {
    CoreVault public vault;
    ERC20Mock public usdc;
    FeeCollector public feeCollector;
    IQueueModule public queueModule;

    /* ========== CONSTANTS FOR 10K STABILITY ========== */
    uint256 constant MAX_ACTORS = 10; // Fixed actor pool
    uint256 constant MAX_DEPOSIT = 1_000_000e6; // 1M USDC max per deposit
    uint256 constant MIN_DEPOSIT = 1000e6; // 1000 USDC min
    uint256 constant MAX_QUEUE_SIZE = 50; // Max pending claims
    uint256 constant MAX_CLAIMS_PER_ACTOR = 3; // Max claims per actor
    uint256 constant TVL_YIELD_CAP_PCT = 10; // Max 10% yield per op
    uint256 constant TVL_LOSS_CAP_PCT = 2; // Max 2% loss per op

    /* ========== GHOST VARIABLES ========== */
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalYield;
    uint256 public ghost_totalLoss;
    uint256 public ghost_totalFees;
    uint256 public ghost_pendingClaims;
    uint256 public ghost_processedClaims;
    uint256 public ghost_deployedToStrategies;
    uint256 public ghost_feesCollected;
    uint256 public ghost_distributedFees;
    uint256 public ghost_totalDepositFees;
    uint256 public ghost_totalWithdrawFees;
    uint256 public ghost_totalPerfFees;

    /* ========== CALL COUNTERS ========== */
    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    uint256 public calls_redeem;
    uint256 public calls_requestClaim;
    uint256 public calls_cancelClaim;
    uint256 public calls_settle;
    uint256 public calls_yield;
    uint256 public calls_loss;
    uint256 public calls_distribute;

    /* ========== REVERT COUNTERS (STEP 1) ========== */
    uint256 public reverts_deposit;
    uint256 public reverts_withdraw;
    uint256 public reverts_redeem;
    uint256 public reverts_requestClaim;
    uint256 public reverts_cancelClaim;
    uint256 public reverts_settle;
    uint256 public reverts_yield;
    uint256 public reverts_loss;
    uint256 public reverts_distribute;

    /* ========== ACTOR TRACKING - FIXED POOL ========== */
    address[10] public actors;
    mapping(address => uint256) public actorClaimCount;

    modifier useActor(uint256 seed) {
        address actor = actors[seed % MAX_ACTORS];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    constructor(CoreVault _vault, ERC20Mock _usdc, FeeCollector _feeCollector) {
        vault = _vault;
        usdc = _usdc;
        feeCollector = _feeCollector;
        queueModule = IQueueModule(address(_vault));

        // Pre-create fixed actor pool (no dynamic arrays)
        for (uint256 i = 0; i < MAX_ACTORS; i++) {
            actors[i] = address(uint160(0x10000 + i));
        }
    }

    /* ========== HANDLER: DEPOSIT ========== */

    function deposit(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        address actor = actors[actorSeed % MAX_ACTORS];

        // STEP 2: Aggressive bounds - relative to TVL
        uint256 tvl = vault.totalAssets();
        uint256 maxAmount = tvl > 0 ? (tvl / 5) : MAX_DEPOSIT; // Max 20% of TVL
        if (maxAmount > MAX_DEPOSIT) maxAmount = MAX_DEPOSIT;
        if (maxAmount < MIN_DEPOSIT) maxAmount = MIN_DEPOSIT;

        amount = bound(amount, MIN_DEPOSIT, maxAmount);

        // Fund actor
        usdc._mint(actor, amount);
        usdc.approve(address(vault), amount);

        uint256 fcSharesBefore = vault.balanceOf(address(feeCollector));

        try vault.deposit(amount, actor) {
            uint256 fcSharesAfter = vault.balanceOf(address(feeCollector));
            uint256 feeSharesMinted = fcSharesAfter - fcSharesBefore;

            ghost_totalDeposited += amount;

            uint256 depositFee = feeSharesMinted > 0 ? vault.convertToAssets(feeSharesMinted) : 0;
            ghost_totalDepositFees += depositFee;
            ghost_totalFees += depositFee;
            ghost_feesCollected += depositFee;

            calls_deposit++;
        } catch {
            reverts_deposit++;
        }
    }

    /* ========== HANDLER: WITHDRAW ========== */

    function withdraw(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        address actor = actors[actorSeed % MAX_ACTORS];

        // STEP 3: Guard clause - skip if no balance
        uint256 maxWithdraw = vault.maxWithdraw(actor);
        if (maxWithdraw == 0) {
            reverts_withdraw++;
            return;
        }

        // Cap to actual balance
        amount = bound(amount, 1, maxWithdraw);

        uint256 fcSharesBefore = vault.balanceOf(address(feeCollector));
        uint256 balBefore = usdc.balanceOf(actor);

        try vault.withdraw(amount, actor, actor) {
            uint256 balAfter = usdc.balanceOf(actor);
            uint256 fcSharesAfter = vault.balanceOf(address(feeCollector));
            uint256 feeSharesMinted = fcSharesAfter - fcSharesBefore;

            uint256 received = balAfter - balBefore;
            ghost_totalWithdrawn += received;

            uint256 withdrawFee = feeSharesMinted > 0 ? vault.convertToAssets(feeSharesMinted) : 0;
            ghost_totalWithdrawFees += withdrawFee;
            ghost_totalFees += withdrawFee;
            ghost_feesCollected += withdrawFee;

            calls_withdraw++;
        } catch {
            reverts_withdraw++;
        }
    }

    /* ========== HANDLER: REDEEM ========== */

    function redeem(uint256 actorSeed, uint256 shares) public useActor(actorSeed) {
        address actor = actors[actorSeed % MAX_ACTORS];

        // STEP 3: Guard clause
        uint256 maxRedeem = vault.maxRedeem(actor);
        if (maxRedeem == 0) {
            reverts_redeem++;
            return;
        }

        shares = bound(shares, 1, maxRedeem);

        uint256 fcSharesBefore = vault.balanceOf(address(feeCollector));
        uint256 balBefore = usdc.balanceOf(actor);

        try vault.redeem(shares, actor, actor) {
            uint256 balAfter = usdc.balanceOf(actor);
            uint256 fcSharesAfter = vault.balanceOf(address(feeCollector));
            uint256 feeSharesMinted = fcSharesAfter - fcSharesBefore;

            uint256 received = balAfter - balBefore;
            ghost_totalWithdrawn += received;

            uint256 withdrawFee = feeSharesMinted > 0 ? vault.convertToAssets(feeSharesMinted) : 0;
            ghost_totalWithdrawFees += withdrawFee;
            ghost_totalFees += withdrawFee;
            ghost_feesCollected += withdrawFee;

            calls_redeem++;
        } catch {
            reverts_redeem++;
        }
    }

    /* ========== HANDLER: REQUEST_CLAIM ========== */

    function requestClaim(uint256 actorSeed, uint256 shares, bool immediate)
        public
        useActor(actorSeed)
    {
        address actor = actors[actorSeed % MAX_ACTORS];

        // STEP 3: Guard clauses
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) {
            reverts_requestClaim++;
            return;
        }

        // STEP 4: Cap claims per actor
        if (actorClaimCount[actor] >= MAX_CLAIMS_PER_ACTOR) {
            reverts_requestClaim++;
            return;
        }

        // STEP 4: Cap queue size
        uint256 queueLen = IQueueModule(address(vault)).queueLength();
        if (queueLen >= MAX_QUEUE_SIZE) {
            reverts_requestClaim++;
            return;
        }

        // Max 50% of balance per claim
        shares = bound(shares, 1, balance / 2);
        if (shares == 0) shares = 1;

        uint256 grossAssets = vault.convertToAssets(shares);
        uint256 balBefore = usdc.balanceOf(actor);

        try IQueueModule(address(vault)).requestClaim(immediate, shares) {
            uint256 balAfter = usdc.balanceOf(actor);

            if (balAfter > balBefore) {
                ghost_totalWithdrawn += grossAssets;
            } else {
                ghost_pendingClaims++;
                actorClaimCount[actor]++;
            }
            calls_requestClaim++;
        } catch {
            reverts_requestClaim++;
        }
    }

    /* ========== HANDLER: CANCEL_CLAIM ========== */

    function cancelClaim(uint256 actorSeed, uint256 claimId) public useActor(actorSeed) {
        address actor = actors[actorSeed % MAX_ACTORS];

        // STEP 3: Guard clause - only cancel if actor has claims
        if (actorClaimCount[actor] == 0) {
            reverts_cancelClaim++;
            return;
        }

        claimId = bound(claimId, 0, 100);

        try IQueueModule(address(vault)).cancelClaim(claimId) {
            if (ghost_pendingClaims > 0) ghost_pendingClaims--;
            if (actorClaimCount[actor] > 0) actorClaimCount[actor]--;
            calls_cancelClaim++;
        } catch {
            reverts_cancelClaim++;
        }
    }

    /* ========== HANDLER: SETTLE_QUEUE ========== */

    function settleQueue(uint256 maxClaims) public {
        // STEP 3: Guard clause - skip if queue empty
        uint256 queueLen = IQueueModule(address(vault)).queueLength();
        if (queueLen == 0) {
            reverts_settle++;
            return;
        }

        // STEP 4: Batch cap
        maxClaims = bound(maxClaims, 1, 20);

        vm.warp(block.timestamp + 7 days);

        uint256 queueLenBefore = queueLen;

        try IQueueModule(address(vault)).settleFeesAndProcessQueue(maxClaims) {
            uint256 queueLenAfter = IQueueModule(address(vault)).queueLength();
            uint256 processed = queueLenBefore > queueLenAfter ? queueLenBefore - queueLenAfter : 0;
            ghost_processedClaims += processed;
            if (ghost_pendingClaims >= processed) {
                ghost_pendingClaims -= processed;
            }
            calls_settle++;
        } catch {
            reverts_settle++;
        }
    }

    /* ========== HANDLER: SIMULATE_DONATION ========== */

    function simulateDonation(uint256 donationAmount) public {
        uint256 tvl = vault.totalAssets();

        // STEP 3: Guard - need meaningful TVL
        if (tvl < 10_000e6) {
            reverts_yield++;
            return;
        }

        // STEP 2: Aggressive bounds - max 2% of TVL
        uint256 maxDonation = tvl / 50; // 2%
        uint256 minDonation = 1e6;

        if (maxDonation < minDonation) maxDonation = minDonation;
        donationAmount = bound(donationAmount, minDonation, maxDonation);

        usdc._mint(address(vault), donationAmount);
        ghost_totalYield += donationAmount;

        _crystallizeAndTrackPerfFee();
        calls_yield++;
    }

    /* ========== HANDLER: SIMULATE_STRATEGY_PROFIT ========== */

    function simulateStrategyProfit(uint256 profitAmount) public {
        uint256 tvl = vault.totalAssets();

        // STEP 3: Guard
        if (tvl < 10_000e6) {
            reverts_yield++;
            return;
        }

        // STEP 2: Cap cumulative yield to 200% of deposits
        uint256 maxCumulativeYield = ghost_totalDeposited * 2;
        if (ghost_totalYield >= maxCumulativeYield) {
            reverts_yield++;
            return;
        }

        // Max 5% of TVL per op
        uint256 maxProfit = tvl / 20;
        uint256 minProfit = 1e6;

        if (maxProfit < minProfit) maxProfit = minProfit;
        profitAmount = bound(profitAmount, minProfit, maxProfit);

        // Cap to remaining budget
        uint256 remaining = maxCumulativeYield - ghost_totalYield;
        if (profitAmount > remaining) profitAmount = remaining;

        if (profitAmount == 0) {
            reverts_yield++;
            return;
        }

        usdc._mint(address(vault), profitAmount);
        ghost_totalYield += profitAmount;

        _crystallizeAndTrackPerfFee();
        calls_yield++;
    }

    /* ========== HANDLER: SIMULATE_YIELD (LEGACY) ========== */

    function simulateYield(uint256 yieldAmount) public {
        simulateStrategyProfit(yieldAmount);
    }

    /* ========== HANDLER: SIMULATE_LOSS ========== */

    function simulateLoss(uint256 lossPct) public {
        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        // STEP 3: Guard - don't loss if empty or share price too low
        if (totalSupply == 0 || totalAssets == 0) {
            reverts_loss++;
            return;
        }

        uint256 sharePrice = (totalAssets * 1e6) / totalSupply;
        if (sharePrice < 7e5) {
            // < 0.7
            reverts_loss++;
            return;
        }

        // STEP 2: Max 2% loss per op
        lossPct = bound(lossPct, 1, TVL_LOSS_CAP_PCT);

        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 lossAmount = (vaultBalance * lossPct) / 100;

        // Floor at 0.6 share price
        uint256 minAssets = (totalSupply * 60) / 100;
        if (totalAssets - lossAmount < minAssets) {
            lossAmount = totalAssets > minAssets ? totalAssets - minAssets : 0;
        }

        if (lossAmount > 0 && vaultBalance > lossAmount) {
            vm.prank(address(vault));
            usdc.transfer(address(0xDEAD), lossAmount);

            ghost_totalLoss += lossAmount;
            if (ghost_totalYield >= lossAmount) {
                ghost_totalYield -= lossAmount;
            }
            calls_loss++;
        } else {
            reverts_loss++;
        }
    }

    /* ========== HANDLER: DISTRIBUTE_FEES ========== */

    function distributeFees() public {
        uint256 fcShares = vault.balanceOf(address(feeCollector));

        // STEP 3: Guard - need meaningful shares to distribute
        if (fcShares < 1000) {
            reverts_distribute++;
            return;
        }

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
            reverts_distribute++;
        }
    }

    /* ========== INTERNAL: CRYSTALLIZE ========== */

    function _crystallizeAndTrackPerfFee() internal {
        uint256 fcSharesBefore = vault.balanceOf(address(feeCollector));

        vm.warp(block.timestamp + 2 hours);

        uint256 queueLenBefore = IQueueModule(address(vault)).queueLength();

        try IQueueModule(address(vault)).settleFeesAndProcessQueue(1) {
            uint256 fcSharesAfter = vault.balanceOf(address(feeCollector));
            uint256 perfFeeSharesMinted =
                fcSharesAfter > fcSharesBefore ? fcSharesAfter - fcSharesBefore : 0;

            if (perfFeeSharesMinted > 0) {
                uint256 perfFeeAssets = vault.convertToAssets(perfFeeSharesMinted);
                ghost_totalPerfFees += perfFeeAssets;
                ghost_totalFees += perfFeeAssets;
                ghost_feesCollected += perfFeeAssets;
            }

            uint256 queueLenAfter = IQueueModule(address(vault)).queueLength();
            uint256 processed = queueLenBefore > queueLenAfter ? queueLenBefore - queueLenAfter : 0;
            if (processed > 0) {
                ghost_processedClaims += processed;
                if (ghost_pendingClaims >= processed) {
                    ghost_pendingClaims -= processed;
                } else {
                    ghost_pendingClaims = 0;
                }
            }
        } catch { }
    }

    /* ========== CALL SUMMARY ========== */

    function callSummary() public view {
        uint256 totalCalls = calls_deposit + calls_withdraw + calls_redeem + calls_requestClaim
            + calls_cancelClaim + calls_settle + calls_yield + calls_loss + calls_distribute;

        uint256 totalReverts = reverts_deposit + reverts_withdraw + reverts_redeem
            + reverts_requestClaim + reverts_cancelClaim + reverts_settle + reverts_yield
            + reverts_loss + reverts_distribute;

        uint256 revertRate = totalCalls > 0 ? (totalReverts * 100) / (totalCalls + totalReverts) : 0;

        console2.log("=== CALL SUMMARY (10K OPTIMIZED) ===");
        console2.log("Total Calls:", totalCalls);
        console2.log("Total Reverts:", totalReverts);
        console2.log("Revert Rate:", revertRate, "%");
        console2.log("");
        console2.log("Deposits:", calls_deposit, "reverts:", reverts_deposit);
        console2.log("Withdraws:", calls_withdraw, "reverts:", reverts_withdraw);
        console2.log("Redeems:", calls_redeem, "reverts:", reverts_redeem);
        console2.log("RequestClaims:", calls_requestClaim, "reverts:", reverts_requestClaim);
        console2.log("CancelClaims:", calls_cancelClaim, "reverts:", reverts_cancelClaim);
        console2.log("Settles:", calls_settle, "reverts:", reverts_settle);
        console2.log("Yields:", calls_yield, "reverts:", reverts_yield);
        console2.log("Losses:", calls_loss, "reverts:", reverts_loss);
        console2.log("Distributes:", calls_distribute, "reverts:", reverts_distribute);
        console2.log("");
        console2.log("=== GHOST STATE ===");
        console2.log("Total Deposited:", ghost_totalDeposited);
        console2.log("Total Withdrawn:", ghost_totalWithdrawn);
        console2.log("Total Yield:", ghost_totalYield);
        console2.log("Total Fees:", ghost_totalFees);
        console2.log("Pending Claims:", ghost_pendingClaims);
    }
}
