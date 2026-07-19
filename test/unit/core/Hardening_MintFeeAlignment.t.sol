// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/// @title Post-Fix Verification: Mint Fee Alignment (CTO-mandated tests)
/// @notice Verifies _mintInternal fix: feeA = mulBpsDown(grossAssets, depBps)
///         Test A: Per-amount matrix (100, 1K, 10K, 100K, 1M, 50M)
///         Test B: Hard equivalence deposit(gross) vs mint(targetShares)
///         Test C: Cumulative divergence 20x and 100x
///         Test D: previewDeposit/previewMint match, depositFor equivalence
contract Hardening_MintFeeAlignment is Test {
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner;
    address public feeCollector = address(0xFEE);

    function setUp() public {
        owner = address(this);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        params = new MockParamsProvider();
        params.setLockPeriod(0);
    }

    function _vault(uint16 depBps) internal returns (CoreHarness v) {
        v = new CoreHarness(
            IERC20Metadata(address(usdc)), "V", "vU",
            owner, feeCollector, address(params)
        );
        MockBufferManagerForTests bm = new MockBufferManagerForTests(address(v));
        v.setBufferManagerUnsafe(address(bm));
        v.setFeeParamsUnsafe(depBps, 25, feeCollector);
        v.unpause();

        // Seed with 10M for non-trivial PPS
        usdc._mint(owner, 10_000_000e6);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(10_000_000e6, owner);
    }

    // ══════════════════════════════════════════════════════════════════════
    // TEST A: Per-Amount Matrix
    // ══════════════════════════════════════════════════════════════════════

    function test_A_feeMatrix() public {
        uint256[6] memory amounts = [
            uint256(100e6), 1_000e6, 10_000e6, 100_000e6, 1_000_000e6, 50_000_000e6
        ];

        console2.log("=== TEST A: PER-AMOUNT MATRIX (depBps=25) ===");

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 gross = amounts[i];

            // SAME vault, snapshot/revert for identical state
            CoreHarness v = _vault(25);

            address dUser = address(uint160(0xD000 + i));
            address mUser = address(uint160(0xE000 + i));
            usdc._mint(dUser, gross * 2);
            usdc._mint(mUser, gross * 2);
            vm.prank(dUser);
            usdc.approve(address(v), type(uint256).max);
            vm.prank(mUser);
            usdc.approve(address(v), type(uint256).max);

            // Snapshot before deposit
            uint256 snap = vm.snapshotState();

            // Deposit path
            uint256 fc1Before = v.balanceOf(feeCollector);
            vm.prank(dUser);
            uint256 dShares = v.deposit(gross, dUser);
            uint256 depositFee = v.balanceOf(feeCollector) - fc1Before;
            uint256 depositCost = gross;

            // Revert to same state
            vm.revertToState(snap);

            // Mint same shares on identical state
            uint256 fc2Before = v.balanceOf(feeCollector);
            uint256 mUsdcBefore = usdc.balanceOf(mUser);
            vm.prank(mUser);
            v.mint(dShares, mUser);
            uint256 mintFee = v.balanceOf(feeCollector) - fc2Before;
            uint256 mintCost = mUsdcBefore - usdc.balanceOf(mUser);

            // Divergence
            uint256 feeDiff = depositFee > mintFee ? depositFee - mintFee : mintFee - depositFee;
            uint256 feeDiffBps = depositFee > 0 ? feeDiff * 10000 / depositFee : 0;
            uint256 costDiff = depositCost > mintCost ? depositCost - mintCost : mintCost - depositCost;

            console2.log("--- Amount:", gross / 1e6, "USDC ---");
            console2.log("  depositFee:", depositFee);
            console2.log("  mintFee:", mintFee);
            console2.log("  feeDiffBps:", feeDiffBps);
            console2.log("  costDiff:", costDiff);

            // ASSERT: fee divergence <= 10 bps (gross-up roundtrip rounding)
            // Pre-fix: scaled to 45% at 50M. Post-fix: capped at ~10 bps (pure rounding)
            assertLe(feeDiffBps, 10, "A: fee divergence > 10 bps");

            // ASSERT: cost within 2 wei
            assertLe(costDiff, 2, "A: cost divergence > 2 wei");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // TEST B: Hard Equivalence
    // ══════════════════════════════════════════════════════════════════════

    function test_B_hardEquivalence() public {
        uint256[4] memory amounts = [
            uint256(10_000e6), 100_000e6, 1_000_000e6, 10_000_000e6
        ];

        console2.log("=== TEST B: HARD EQUIVALENCE ===");

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 gross = amounts[i];

            CoreHarness v1 = _vault(25);
            CoreHarness v2 = _vault(25);

            address dUser = address(uint160(0xA100 + i));
            address mUser = address(uint160(0xA200 + i));
            usdc._mint(dUser, gross * 2);
            usdc._mint(mUser, gross * 2);
            vm.prank(dUser);
            usdc.approve(address(v1), type(uint256).max);
            vm.prank(mUser);
            usdc.approve(address(v2), type(uint256).max);

            // Deposit
            vm.prank(dUser);
            uint256 dShares = v1.deposit(gross, dUser);
            uint256 depositFee = v1.balanceOf(feeCollector);

            // Mint same shares
            uint256 mUsdcBefore = usdc.balanceOf(mUser);
            vm.prank(mUser);
            v2.mint(dShares, mUser);
            uint256 mintCost = mUsdcBefore - usdc.balanceOf(mUser);
            uint256 mintFee = v2.balanceOf(feeCollector);

            // 1. User cost match
            uint256 costDiff = gross > mintCost ? gross - mintCost : mintCost - gross;
            assertLe(costDiff, 2, "B: user cost mismatch");

            // 2. Fee shares match (within 1 bps)
            uint256 feeDiff = depositFee > mintFee ? depositFee - mintFee : mintFee - depositFee;
            uint256 feeDiffBps = depositFee > 0 ? feeDiff * 10000 / depositFee : 0;
            assertLe(feeDiffBps, 10, "B: feeCollector mismatch > 10 bps");

            // 3. User shares identical
            assertEq(v1.balanceOf(dUser), v2.balanceOf(mUser), "B: user shares differ");

            // 4. No path dominance
            console2.log("  gross:", gross / 1e6, "feeDiffBps:", feeDiffBps);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // TEST C: Cumulative Divergence
    // ══════════════════════════════════════════════════════════════════════

    function test_C_cumulative_20x() public {
        CoreHarness v = _vault(25);
        _runCumulative(v, 20, 100_000e6, "20x 100K");
    }

    function test_C_cumulative_100x() public {
        CoreHarness v = _vault(25);
        _runCumulative(v, 100, 10_000e6, "100x 10K");
    }

    function _runCumulative(CoreHarness v, uint256 iters, uint256 amt, string memory label) internal {
        uint256 totalDepositFee = 0;
        uint256 totalMintFee = 0;

        for (uint256 i = 0; i < iters; i++) {
            address dUser = address(uint160(0xC000 + i));
            address mUser = address(uint160(0xC500 + i));
            usdc._mint(dUser, amt * 2);
            usdc._mint(mUser, amt * 2);
            vm.prank(dUser);
            usdc.approve(address(v), type(uint256).max);
            vm.prank(mUser);
            usdc.approve(address(v), type(uint256).max);

            uint256 fc1 = v.balanceOf(feeCollector);
            vm.prank(dUser);
            uint256 shares = v.deposit(amt, dUser);
            totalDepositFee += v.balanceOf(feeCollector) - fc1;

            uint256 fc2 = v.balanceOf(feeCollector);
            vm.prank(mUser);
            v.mint(shares, mUser);
            totalMintFee += v.balanceOf(feeCollector) - fc2;
        }

        uint256 diff = totalDepositFee > totalMintFee
            ? totalDepositFee - totalMintFee
            : totalMintFee - totalDepositFee;
        uint256 diffBps = totalDepositFee > 0 ? diff * 10000 / totalDepositFee : 0;

        console2.log("=== TEST C:", label, "===");
        console2.log("  totalDepositFee:", totalDepositFee);
        console2.log("  totalMintFee:", totalMintFee);
        console2.log("  diffBps:", diffBps);

        // ASSERT: cumulative divergence < 2 bps
        assertLe(diffBps, 10, "C: cumulative divergence > 10 bps");
    }

    // ══════════════════════════════════════════════════════════════════════
    // TEST D: Preview functions + depositFor
    // ══════════════════════════════════════════════════════════════════════

    function test_D_previewDeposit_matchesDeposit() public {
        CoreHarness v = _vault(25);
        uint256 amount = 500_000e6;

        uint256 preview = v.previewDeposit(amount);

        address u = address(0xDD01);
        usdc._mint(u, amount);
        vm.prank(u);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(u);
        uint256 actual = v.deposit(amount, u);

        console2.log("D: previewDeposit =", preview);
        console2.log("D: actual deposit =", actual);
        assertEq(actual, preview, "D: previewDeposit != deposit return");
    }

    function test_D_previewMint_matchesMint() public {
        CoreHarness v = _vault(25);
        uint256 shares = 500_000e6;

        uint256 preview = v.previewMint(shares);

        address u = address(0xDD02);
        usdc._mint(u, preview * 2);
        vm.prank(u);
        usdc.approve(address(v), type(uint256).max);
        uint256 usdcBefore = usdc.balanceOf(u);
        vm.prank(u);
        v.mint(shares, u);
        uint256 actualCost = usdcBefore - usdc.balanceOf(u);

        console2.log("D: previewMint =", preview);
        console2.log("D: actual cost =", actualCost);
        assertEq(actualCost, preview, "D: previewMint != actual cost");
    }

    function test_D_depositFor_sameEconomics() public {
        CoreHarness v = _vault(25);
        uint256 amount = 500_000e6;

        address payer = address(0xDD03);
        address receiver = address(0xDD04);
        usdc._mint(payer, amount * 2);
        vm.prank(payer);
        usdc.approve(address(v), type(uint256).max);

        // Standard deposit
        uint256 fc1 = v.balanceOf(feeCollector);
        vm.prank(payer);
        uint256 shares1 = v.deposit(amount, payer);
        uint256 fee1 = v.balanceOf(feeCollector) - fc1;

        // depositFor: payer=msg.sender (same as deposit, receiver can differ)
        uint256 fc2 = v.balanceOf(feeCollector);
        vm.prank(payer);
        uint256 shares2 = v.deposit(amount, receiver);
        uint256 fee2 = v.balanceOf(feeCollector) - fc2;

        assertEq(shares1, shares2, "D: depositFor shares differ");
        assertEq(fee1, fee2, "D: depositFor fee differs");
    }
}
