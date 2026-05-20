// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { FeeCollector } from "../../../src/core/modules/FeeCollector.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { QueueModule } from "../../../src/core/modules/QueueModule.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { IQueueModule } from "../../../src/interfaces/IQueueModule.sol";

/**
 * @title SharePriceCollapse_Security
 * @notice Security tests for extreme share price scenarios
 * @dev Tests what happens when share price collapses or spikes
 */
contract SharePriceCollapse_Security is Test {
    CoreHarness public vault;
    FeeCollector public feeCollector;
    MockParamsProvider public params;
    ERC20Mock public usdc;
    QueueModule public queueModule;
    AdminModule public adminModule;

    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public treasury = address(0xFEE1);
    address public opsSafe = address(0xFEE2);
    address public safetyReserve = address(0xFEE3);

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0); // No lock for these tests

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

        // Deploy CoreHarness (wires all modules + unpauses automatically)
        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
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
     * @notice Test share price collapse scenario
     * @dev What happens when vault loses 90% of assets?
     */
    function test_sharePriceCollapse_90Percent() public {
        // Alice deposits 1M USDC
        usdc._mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "Alice should have shares");

        // Bob deposits 500k USDC
        usdc._mint(bob, 500_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500_000e6);
        vault.deposit(500_000e6, bob);
        vm.stopPrank();

        uint256 bobShares = vault.balanceOf(bob);

        // Initial share price should be ~1.0
        uint256 initialPrice = vault.convertToAssets(1e18);
        console2.log("Initial share price:", initialPrice);
        assertApproxEqRel(initialPrice, 1e18, 0.05e18, "Initial price ~1.0");

        // CATASTROPHIC LOSS: Vault loses 90% of assets
        uint256 totalAssets = vault.totalAssets();
        uint256 lossAmount = (totalAssets * 90) / 100;

        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), lossAmount);

        // Share price should collapse to ~0.1
        uint256 collapsedPrice = vault.convertToAssets(1e18);
        console2.log("Collapsed share price:", collapsedPrice);
        assertLt(collapsedPrice, 0.15e18, "Price should collapse");
        assertGt(collapsedPrice, 0, "Price should not be zero");

        // Alice requests claim
        vm.startPrank(alice);
        IQueueModule(address(vault)).requestClaim(false, aliceShares);
        vm.stopPrank();

        // Check claim value
        uint256 claimValue = vault.convertToAssets(aliceShares);
        console2.log("Alice claim value (USDC):", claimValue / 1e6);

        // CRITICAL: Alice's 1M deposit is now worth only ~100k
        // This is economically correct BUT the system should handle it gracefully
        assertGt(claimValue, 0, "Claim should have value");

        // Try to settle
        vm.warp(block.timestamp + 7 days);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        // Verify Alice received something (not 0)
        uint256 aliceBalance = usdc.balanceOf(alice);
        assertGt(aliceBalance, 0, "Alice should receive assets");

        // Loss should be proportional to share ownership
        console2.log("Alice recovered (USDC):", aliceBalance / 1e6);
    }

    /**
     * @notice Test conversion when share price is extremely low
     * @dev Check for rounding to zero issues
     */
    function test_convertToAssets_extremelyLowPrice() public {
        // Setup: 1M shares, 1k assets = price 0.001
        usdc._mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        // Catastrophic loss: 99.9% gone
        uint256 totalAssets = vault.totalAssets();
        uint256 lossAmount = (totalAssets * 999) / 1000;
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), lossAmount);

        // Share price should be ~0.001
        uint256 sharePrice = vault.convertToAssets(1e18);
        console2.log("Extreme low price:", sharePrice);

        // Small share amounts may round to 0
        uint256 smallShares = 1000; // 1000 wei shares
        uint256 assets = vault.convertToAssets(smallShares);
        console2.log("1000 shares -> assets:", assets);

        // This may be 0 due to rounding - is this a bug?
        if (assets == 0) {
            console2.log("WARNING: Small shares convert to 0 assets");
        }
    }

    /**
     * @notice Test pending claims when vault collapses
     * @dev Escrowed shares should still work correctly
     */
    function test_pendingClaims_duringCollapse() public {
        // Alice and Bob deposit
        usdc._mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        usdc._mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);

        // Alice requests claim (shares escrowed)
        vm.startPrank(alice);
        IQueueModule(address(vault)).requestClaim(false, aliceShares);
        vm.stopPrank();

        uint256 pendingShares = IQueueModule(address(vault)).pendingShares();
        assertEq(pendingShares, aliceShares, "Shares should be escrowed");

        // Check that escrowed shares are held by vault
        uint256 vaultShares = vault.balanceOf(address(vault));
        assertEq(vaultShares, aliceShares, "Vault should hold escrowed shares");

        // COLLAPSE: 80% loss
        uint256 totalAssets = vault.totalAssets();
        uint256 lossAmount = (totalAssets * 80) / 100;
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), lossAmount);

        // Share price collapses
        uint256 sharePrice = vault.convertToAssets(1e18);
        console2.log("Share price after collapse:", sharePrice);

        // Settle Alice's claim
        vm.warp(block.timestamp + 7 days);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        // Alice should receive proportional assets
        uint256 aliceBalance = usdc.balanceOf(alice);
        console2.log("Alice received:", aliceBalance / 1e6, "USDC");
        assertGt(aliceBalance, 0, "Alice should receive assets");

        // pendingShares should be reduced
        assertEq(
            IQueueModule(address(vault)).pendingShares(), 0, "Pending shares should be cleared"
        );
        assertEq(vault.balanceOf(address(vault)), 0, "Vault should not hold shares");
    }

    /**
     * @notice Test CORRECT share accounting during collapse
     * @dev CORRECTED: balanceOf(vault) should equal pendingShares
     *      NOT totalSupply + pendingShares (that double-counts escrowed shares)
     */
    function test_shareAccounting_duringCollapse() public {
        usdc._mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        uint256 initialSupply = vault.totalSupply();

        // Request 50% claim
        uint256 claimShares = initialSupply / 2;
        vm.startPrank(alice);
        IQueueModule(address(vault)).requestClaim(false, claimShares);
        vm.stopPrank();

        // CORRECT accounting check BEFORE collapse
        // Escrowed shares are in vault balance AND counted in pendingShares
        uint256 vaultBalance = vault.balanceOf(address(vault));
        uint256 pendingShares = IQueueModule(address(vault)).pendingShares();
        assertEq(vaultBalance, pendingShares, "Vault balance should equal pending shares");

        // totalSupply stays the same (shares transferred, not burned)
        assertEq(vault.totalSupply(), initialSupply, "totalSupply unchanged after request");

        // COLLAPSE
        uint256 totalAssets = vault.totalAssets();
        vm.prank(address(vault));
        usdc.transfer(address(0xDEAD), (totalAssets * 90) / 100);

        // Accounting check AFTER collapse (before settlement)
        assertEq(
            vault.balanceOf(address(vault)),
            IQueueModule(address(vault)).pendingShares(),
            "Escrow accounting should survive collapse"
        );
        assertEq(vault.totalSupply(), initialSupply, "totalSupply still unchanged");

        // Settle
        vm.warp(block.timestamp + 7 days);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(1);

        // After settlement, escrowed shares are burned
        assertTrue(vault.totalSupply() < initialSupply, "Shares should be burned");
        assertEq(IQueueModule(address(vault)).pendingShares(), 0, "No pending shares");
        assertEq(vault.balanceOf(address(vault)), 0, "Vault should not hold shares");
    }
}
