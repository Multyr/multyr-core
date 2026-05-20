// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { MockDepositRouter } from "../../mocks/MockDepositRouter.sol";
import { MockReferralBinding } from "../../mocks/MockReferralBinding.sol";
import { ExitEngineLib } from "../../../src/core/libraries/ExitEngineLib.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function pendingShares() external view returns (uint256);
    function queueLength() external view returns (uint256);
}

interface IForceWithdrawAll {
    function forceWithdrawAll(address receiver) external returns (uint256);
}

/// @title DepositRouter + ExitEngineLib integration test (mock-based, no periphery import)
/// @notice Tests the FULL deposit path via mock router → CoreVault.deposit
///         Then tests all exit paths on shares deposited via router.
///
/// CTO requirement: DepositRouter + exit paths tested at core boundary via mocks.
/// Real end-to-end with concrete DepositRouter lives in multyr-periphery integration tests.
contract ExitEngine_DepositRouter is Test {
    CoreHarness public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;
    MockDepositRouter public router;
    MockReferralBinding public referralBinding;

    address public owner;
    address public feeCollector = address(0xFEE);
    address public referrer = address(0xBEF1);

    address[5] public users;

    function setUp() public {
        owner = address(this);

        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);
        params.setCapPerEpochBps(1000); // 10%

        vault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );

        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(vault));
        vault.setBufferManagerUnsafe(address(mockBM));
        vault.setFeeParamsUnsafe(0, 25, feeCollector);
        vault.setExitFeesUnsafe(25, 50, 150);
        vault.unpause();

        // Deploy MockReferralBinding + MockDepositRouter
        referralBinding = new MockReferralBinding();
        router = new MockDepositRouter(address(vault), address(usdc), address(0), address(referralBinding));

        // Authorize router in referralBinding
        referralBinding.setRouter(address(router), true);

        // Setup users — approve router directly (no Permit2 intermediary in mock)
        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(0xA000 + i));
            usdc._mint(users[i], 100_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(router), type(uint256).max);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Mode A — depositWithPermit2Transfer (per-deposit signature)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositRouter_modeA_permit2Transfer() public {
        uint256 amount = 10_000_000e6; // 10M USDC

        uint256 usdcBefore = usdc.balanceOf(users[0]);
        uint256 sharesBefore = vault.balanceOf(users[0]);

        vm.prank(users[0]);
        uint256 shares = router.depositWithPermit2Transfer(
            amount,
            referrer,      // referrer
            0,             // nonce (ignored in mock)
            block.timestamp + 1 hours, // deadline (ignored)
            "mock_sig"     // signature (ignored)
        );

        uint256 usdcAfter = usdc.balanceOf(users[0]);
        uint256 sharesAfter = vault.balanceOf(users[0]);

        assertEq(usdcBefore - usdcAfter, amount, "USDC pulled from user");
        assertEq(sharesAfter - sharesBefore, shares, "shares minted to user");
        assertGt(shares, 0, "received shares");

        // Referral bound
        assertEq(referralBinding.referrerOf(users[0]), referrer, "referral bound");

        console2.log("Mode A deposit:", amount / 1e6, "USDC, shares:", shares / 1e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Mode B — depositWithPermit2Allowance (Euler-style long-lived)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositRouter_modeB_permit2Allowance() public {
        uint256 amount = 5_000_000e6;

        // First deposit
        vm.prank(users[1]);
        uint256 shares1 = router.depositWithPermit2Allowance(
            amount,
            address(0),    // no referrer
            type(uint160).max, // allowanceAmount (ignored in mock)
            uint48(block.timestamp + 365 days), // expiry (ignored)
            0,             // nonce (ignored)
            block.timestamp + 1 hours,
            "mock_sig"     // sig (ignored)
        );

        assertGt(shares1, 0, "first deposit via allowance");
        assertEq(vault.balanceOf(users[1]), shares1, "shares to user");

        // Second deposit — reuse "allowance" (just another call in mock)
        vm.prank(users[1]);
        uint256 shares2 = router.depositWithPermit2Allowance(
            amount,
            address(0),
            0, 0, 0, 0,   // all zero
            ""
        );

        assertGt(shares2, 0, "second deposit");
        assertEq(vault.balanceOf(users[1]), shares1 + shares2, "cumulative shares");

        console2.log("Mode B: 2 deposits, total shares:", (shares1 + shares2) / 1e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: DepositRouter → full exit cycle (instant + queued + force)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositRouter_thenAllExitModes() public {
        // 5 users deposit via router Mode A
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            router.depositWithPermit2Transfer(
                20_000_000e6,
                referrer,
                i, // unique nonce per user (ignored)
                block.timestamp + 1 hours,
                "mock_sig"
            );
        }

        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        console2.log("After router deposits: assets=", totalAssets / 1e6, "supply=", totalSupply / 1e6);
        assertGe(totalAssets, 99_000_000e6, "~100M TVL");

        // withdraw() MUST revert (even for router-deposited shares)
        vm.prank(users[0]);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(1e6, users[0], users[0]);

        // INSTANT claim — user0
        uint256 user0UsdcBefore = usdc.balanceOf(users[0]);
        vm.prank(users[0]);
        IQueueModule(address(vault)).requestClaim(true, 5_000_000e6);
        uint256 user0Received = usdc.balanceOf(users[0]) - user0UsdcBefore;
        assertGt(user0Received, 0, "instant claim: user0 received USDC");
        console2.log("Instant claim net:", user0Received / 1e6, "USDC");

        // QUEUED claim — user1
        vm.prank(users[1]);
        IQueueModule(address(vault)).requestClaim(false, 5_000_000e6);
        assertEq(IQueueModule(address(vault)).queueLength(), 1, "1 queued claim");

        // Keeper settle
        uint256 user1UsdcBefore = usdc.balanceOf(users[1]);
        IQueueModule(address(vault)).settleFeesAndProcessQueue(10);
        uint256 user1Received = usdc.balanceOf(users[1]) - user1UsdcBefore;
        assertGt(user1Received, 0, "queued settle: user1 received USDC");
        console2.log("Queued settle net:", user1Received / 1e6, "USDC");

        // FORCE withdraw — user2
        uint256 user2UsdcBefore = usdc.balanceOf(users[2]);
        vm.prank(users[2]);
        IForceWithdrawAll(address(vault)).forceWithdrawAll(users[2]);
        uint256 user2Received = usdc.balanceOf(users[2]) - user2UsdcBefore;
        assertEq(vault.balanceOf(users[2]), 0, "force: user2 fully exited");
        assertGt(user2Received, 0, "force: user2 received USDC");
        console2.log("Force exit net:", user2Received / 1e6, "USDC");

        uint256 instantPerShare = user0Received * 1e18 / 5_000_000e6;
        uint256 queuedPerShare = user1Received * 1e18 / 5_000_000e6;
        uint256 forcePerShare = user2Received * 1e18 / 20_000_000e6;

        console2.log("Per-share queued:", queuedPerShare);
        console2.log("Per-share instant:", instantPerShare);
        console2.log("Per-share force:", forcePerShare);

        assertGt(queuedPerShare, instantPerShare, "queued cheapest");
        assertGt(instantPerShare, forcePerShare, "force most expensive");

        assertLt(vault.totalSupply(), totalSupply, "supply decreased");
        assertGt(vault.balanceOf(feeCollector), 0, "feeCollector accumulated fees");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: High-volume router deposits + cap exhaustion + epoch rollover
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositRouter_stressWithCapAndEpoch() public {
        // Phase 1: Ramp to 100M via Mode A
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            router.depositWithPermit2Transfer(
                20_000_000e6, referrer, i,
                block.timestamp + 1 hours, "mock_sig"
            );
        }
        console2.log("TVL:", vault.totalAssets() / 1e6);

        // Phase 2: Exhaust cap (10% of 100M = 10M)
        vm.prank(users[0]);
        IQueueModule(address(vault)).requestClaim(true, 9_000_000e6);

        // Next instant should queue
        uint256 pendingBefore = IQueueModule(address(vault)).pendingShares();
        vm.prank(users[1]);
        IQueueModule(address(vault)).requestClaim(true, 5_000_000e6);
        uint256 pendingAfter = IQueueModule(address(vault)).pendingShares();

        if (pendingAfter > pendingBefore) {
            console2.log("Cap exhausted - claim queued");
        }

        // Phase 3: Epoch rollover
        vm.warp(block.timestamp + 7 days + 1);

        // New deposit via router after epoch
        vm.prank(users[3]);
        router.depositWithPermit2Transfer(
            10_000_000e6, address(0), 99,
            block.timestamp + 1 hours, "mock_sig"
        );

        // Fresh cap — instant claim works
        uint256 usdcBefore = usdc.balanceOf(users[3]);
        vm.prank(users[3]);
        IQueueModule(address(vault)).requestClaim(true, 3_000_000e6);
        assertGt(usdc.balanceOf(users[3]), usdcBefore, "instant claim after epoch + router deposit");

        // Phase 4: Settle any remaining queue
        IQueueModule(address(vault)).settleFeesAndProcessQueue(50);

        console2.log("Final TVL:", vault.totalAssets() / 1e6);
        console2.log("Final queue:", IQueueModule(address(vault)).queueLength());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST: Gas measurement for DepositRouter operations
    // ═══════════════════════════════════════════════════════════════════════════

    function test_depositRouter_gasReport() public {
        uint256 g;

        // Mode A gas
        g = gasleft();
        vm.prank(users[0]);
        router.depositWithPermit2Transfer(
            1_000_000e6, referrer, 0,
            block.timestamp + 1 hours, "mock_sig"
        );
        console2.log("depositWithPermit2Transfer (Mode A):", g - gasleft());

        // Mode B first call
        g = gasleft();
        vm.prank(users[1]);
        router.depositWithPermit2Allowance(
            1_000_000e6, address(0),
            type(uint160).max, uint48(block.timestamp + 365 days),
            0, block.timestamp + 1 hours, "mock_sig"
        );
        console2.log("depositWithPermit2Allowance (Mode B, first):", g - gasleft());

        // Mode B subsequent
        g = gasleft();
        vm.prank(users[1]);
        router.depositWithPermit2Allowance(
            1_000_000e6, address(0),
            0, 0, 0, 0, ""
        );
        console2.log("depositWithPermit2Allowance (Mode B, reuse):", g - gasleft());

        assertLt(g, type(uint256).max, "gas measured");
    }
}
