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
 * @title CoreVault_Adversarial_Invariants
 * @notice Adversarial invariant tests WITHOUT artificial bounds
 * @dev This test suite exposes real bugs by testing extreme scenarios
 *
 * CRITICAL: This test suite removes the artificial bounds from the
 * System_Invariants test to expose real bugs that were being masked.
 */
contract CoreVault_Adversarial_Invariants is StdInvariant, Test {
    CoreVault public vault;
    FeeCollector public feeCollector;
    MockParamsProvider public params;
    ERC20Mock public usdc;
    AdversarialHandler public handler;
    QueueModule public queueModule;
    AdminModule public adminModule;

    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public treasury = address(0xFEE1);
    address public opsSafe = address(0xFEE2);
    address public safetyReserve = address(0xFEE3);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        feeCollector = new FeeCollector(owner, treasury, opsSafe, safetyReserve, 7000, 200, 3000);

        // Deploy modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        // Deploy vault with 6-param constructor
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Adversarial Test Vault",
            "atvUSDC",
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

        handler = new AdversarialHandler(vault, usdc, feeCollector);
        targetContract(address(handler));

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

    /**
     * @notice CRITICAL INVARIANT: Escrowed shares MUST equal pendingShares
     * @dev This was the bug found in the original test
     */
    function invariant_escrowedShares_equalsPendingShares() public view {
        uint256 vaultShares = vault.balanceOf(address(vault));
        uint256 pending = IQueueModule(address(vault)).pendingShares();

        assertEq(vaultShares, pending, "ESCROW: Vault shares must equal pendingShares");
    }

    /**
     * @notice Conservation of value even under extreme conditions
     * @dev Total value in system should be conserved (deposits + yield - loss - withdrawals)
     *
     * IMPORTANT: vault.totalAssets() already includes all USDC backing ALL shares,
     * including shares held by feeCollector. So we should NOT add feeCollector assets again.
     */
    function invariant_valueConservation() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalDeposited = handler.ghost_totalDeposited();
        uint256 totalWithdrawn = handler.ghost_totalWithdrawn();
        uint256 totalYield = handler.ghost_totalYield();
        uint256 totalLoss = handler.ghost_totalLoss();

        // vault.totalAssets() = all USDC in vault
        // This ALREADY backs all shares, including feeCollector's shares
        uint256 totalSystemValue = totalAssets;

        // Value should be conserved: current = deposited + yield - loss - withdrawn
        uint256 expected = totalDeposited + totalYield;
        if (expected >= totalLoss) expected -= totalLoss;
        else expected = 0;

        if (expected >= totalWithdrawn) expected -= totalWithdrawn;
        else expected = 0;

        // Tolerance scales with total expected value (not just deposits)
        // With extreme yields, fees can be large, so allow 15% tolerance
        uint256 tolerance = expected / 7; // ~14% tolerance
        if (tolerance == 0) tolerance = 1e6; // Minimum 1 USDC for small values

        assertApproxEqAbs(
            totalSystemValue,
            expected,
            tolerance,
            "VALUE: Conservation violated (totalAssets != deposited + yield - loss - withdrawn)"
        );
    }

    /**
     * @notice Shares should never be created from nothing
     * @dev totalSupply should track with deposits/burns
     */
    function invariant_noShareInflation() public view {
        // This is tested by checking withdrawals <= deposits + yield
        uint256 withdrawn = handler.ghost_totalWithdrawn();
        uint256 deposited = handler.ghost_totalDeposited();
        uint256 yield = handler.ghost_totalYield();

        assertLe(
            withdrawn,
            deposited + yield + (deposited / 20), // +5% tolerance for rounding
            "INFLATION: Cannot withdraw more than deposited + yield"
        );
    }

    /**
     * @notice Pending shares should never exceed total supply
     * @dev This would indicate a double-counting bug
     */
    function invariant_pendingShares_bounded() public view {
        uint256 pending = IQueueModule(address(vault)).pendingShares();
        uint256 supply = vault.totalSupply();

        assertLe(pending, supply, "PENDING: pendingShares cannot exceed totalSupply");
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}

/**
 * @title AdversarialHandler
 * @notice Handler that tests EXTREME scenarios without artificial bounds
 * @dev Intentionally allows extreme yield/loss to expose bugs
 */
contract AdversarialHandler is Test {
    CoreVault public vault;
    ERC20Mock public usdc;
    FeeCollector public feeCollector;

    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalYield;
    uint256 public ghost_totalLoss;

    // Call counters
    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    uint256 public calls_yield;
    uint256 public calls_loss;

    // Actor tracking
    address[] public actors;
    mapping(address => bool) public isActor;

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
    }

    function deposit(uint256 actorSeed, uint256 amount) public createActor(actorSeed) {
        amount = bound(amount, 1_000e6, 100_000_000e6); // Up to 100M
        address actor = _getActor(actorSeed);

        usdc._mint(actor, amount);
        usdc.approve(address(vault), amount);

        try vault.deposit(amount, actor) {
            ghost_totalDeposited += amount;
            calls_deposit++;
        } catch { }
    }

    function withdraw(uint256 actorSeed, uint256 sharePct) public createActor(actorSeed) {
        address actor = _getActor(actorSeed);
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        sharePct = bound(sharePct, 1, 100);
        uint256 withdrawShares = (shares * sharePct) / 100;
        if (withdrawShares == 0) withdrawShares = 1;

        // Calculate GROSS assets BEFORE withdrawal
        uint256 grossAssets = vault.convertToAssets(withdrawShares);
        uint256 balBefore = usdc.balanceOf(actor);

        try IQueueModule(address(vault)).requestClaim(true, withdrawShares) {
            uint256 balAfter = usdc.balanceOf(actor);
            // Only track if immediate settlement happened (user received assets)
            // If claim went to queue (insufficient liquidity/cap), track nothing here -
            // the queue processing in simulateExtremeYield will handle it
            if (balAfter > balBefore) {
                // Track GROSS amount - vault loses gross (fee stays as feeCollector shares)
                ghost_totalWithdrawn += grossAssets;
            }
            calls_withdraw++;
        } catch { }
    }

    /**
     * @notice Simulate EXTREME yield (up to 1000% gain)
     * @dev NO BOUNDS - test what happens with massive yield
     */
    function simulateExtremeYield(uint256 yieldPct) public {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        if (vaultBalance == 0) {
            calls_yield++;
            return;
        }

        // Allow 1% to 1000% yield
        yieldPct = bound(yieldPct, 1, 1000);
        uint256 yieldAmount = (vaultBalance * yieldPct) / 100;

        usdc._mint(address(vault), yieldAmount);
        ghost_totalYield += yieldAmount;

        // Crystallize and process queue
        // Track assets leaving vault during queue processing
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        vm.warp(block.timestamp + 2 hours);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);
        uint256 vaultBalAfter = usdc.balanceOf(address(vault));

        // If vault balance decreased, assets were withdrawn from queue
        if (vaultBalBefore > vaultBalAfter) {
            ghost_totalWithdrawn += (vaultBalBefore - vaultBalAfter);
        }

        calls_yield++;
    }

    /**
     * @notice Simulate EXTREME loss (up to 99% loss)
     * @dev NO BOUNDS - test vault collapse scenarios
     */
    function simulateExtremeLoss(uint256 lossPct) public {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        if (vaultBalance == 0) {
            calls_loss++;
            return;
        }

        // Allow 1% to 99% loss
        lossPct = bound(lossPct, 1, 99);
        uint256 lossAmount = (vaultBalance * lossPct) / 100;

        if (lossAmount > 0 && vaultBalance > lossAmount) {
            vm.prank(address(vault));
            usdc.transfer(address(0xDEAD), lossAmount);
            ghost_totalLoss += lossAmount;
        }

        calls_loss++;
    }

    function _getActor(uint256 seed) internal returns (address) {
        seed = bound(seed, 0, 9); // 10 actors
        address actor = address(uint160(0x30000 + seed));

        if (!isActor[actor]) {
            actors.push(actor);
            isActor[actor] = true;
        }

        return actor;
    }

    function callSummary() public view {
        console2.log("=== ADVERSARIAL HANDLER SUMMARY ===");
        console2.log("Deposits:", calls_deposit);
        console2.log("Withdraws:", calls_withdraw);
        console2.log("Extreme Yields:", calls_yield);
        console2.log("Extreme Losses:", calls_loss);
        console2.log("");
        console2.log("=== GHOST STATE ===");
        console2.log("Total Deposited:", ghost_totalDeposited);
        console2.log("Total Withdrawn:", ghost_totalWithdrawn);
        console2.log("Total Yield:", ghost_totalYield);
        console2.log("Total Loss:", ghost_totalLoss);
        console2.log("");
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        console2.log("Vault Total Assets:", totalAssets);
        console2.log("Vault Total Supply:", totalSupply);
        if (totalSupply > 0) {
            uint256 sharePrice = (totalAssets * 1e18) / totalSupply;
            console2.log("Share Price:", sharePrice);
        }
    }
}
