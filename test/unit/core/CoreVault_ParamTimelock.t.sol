// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { AdminModule } from "../../../src/core/modules/AdminModule.sol";
import { IAdminModule } from "../../../src/interfaces/IAdminModule.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";

/**
 * @title CoreVault_ParamTimelock
 * @notice Test suite for the parameter timelock governance system
 * @dev Tests submit/accept/revoke/veto flows for fee params, perf params, and minDelay
 */
contract CoreVault_ParamTimelock is Test {
    CoreVault internal vault;
    AdminModule internal adminModule;
    ERC20Mock internal usdc;

    address internal owner = address(0xA11CE);
    address internal feeCollector = address(0xFEE);
    address internal vetoer = address(0xBEE1);
    address internal user = address(0xBEEF);

    uint64 internal constant DEFAULT_MIN_DELAY = 2 days;
    uint64 internal constant PARAM_MAX_WINDOW = 7 days;

    event FeeParamsSubmitted(
        uint16 depositFeeBps, uint16 withdrawFeeBps, address treasury, uint64 eta
    );
    event FeeParamsAccepted(uint16 depositFeeBps, uint16 withdrawFeeBps, address treasury);
    event FeeParamsRevoked();
    event PerfParamsSubmitted(uint256 perfRateX, uint64 minInterval, uint64 eta);
    event PerfParamsAccepted(uint256 perfRateX, uint64 minInterval);
    event PerfParamsRevoked();

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(address(this), 1_000_000e6);
        usdc._mint(user, 100_000e6);

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy AdminModule
        adminModule = new AdminModule();

        // Deploy vault with new 6-param constructor
        vm.prank(owner);
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tvUSDC",
            owner,
            feeCollector,
            address(params)
        );

        // Wire up AdminModule to CoreVault
        bytes4[] memory adminSelectors = new bytes4[](18);
        adminSelectors[0] = IAdminModule.submitFeeParams.selector;
        adminSelectors[1] = IAdminModule.acceptFeeParams.selector;
        adminSelectors[2] = IAdminModule.revokeFeeParams.selector;
        adminSelectors[3] = IAdminModule.submitPerfParams.selector;
        adminSelectors[4] = IAdminModule.acceptPerfParams.selector;
        adminSelectors[5] = IAdminModule.revokePerfParams.selector;
        adminSelectors[6] = IAdminModule.submitMinDelay.selector;
        adminSelectors[7] = IAdminModule.acceptMinDelay.selector;
        adminSelectors[8] = IAdminModule.revokeMinDelay.selector;
        adminSelectors[9] = IAdminModule.setVetoer.selector;
        adminSelectors[10] = IAdminModule.freezeParams.selector;
        adminSelectors[11] = IAdminModule.getPendingFeeParams.selector;
        adminSelectors[12] = IAdminModule.getPendingPerfParams.selector;
        adminSelectors[13] = IAdminModule.getPendingMinDelay.selector;
        adminSelectors[14] = IAdminModule.getFeeParams.selector;
        adminSelectors[15] = IAdminModule.getPerfParams.selector;
        adminSelectors[16] = IAdminModule.getMinDelay.selector;
        adminSelectors[17] = IAdminModule.isParamsFrozen.selector;

        vm.startPrank(owner);
        ModuleSetter.setModulesSame(
            address(vault),
            adminSelectors,
            address(adminModule),
            vault.ROLE_OWNER() // Owner-only for admin functions
        );

        // Make view functions public
        bytes4[] memory viewSelectors = new bytes4[](5);
        viewSelectors[0] = IAdminModule.getPendingFeeParams.selector;
        viewSelectors[1] = IAdminModule.getPendingPerfParams.selector;
        viewSelectors[2] = IAdminModule.getPendingMinDelay.selector;
        viewSelectors[3] = IAdminModule.getFeeParams.selector;
        viewSelectors[4] = IAdminModule.getPerfParams.selector;

        ModuleSetter.setModulesSame(
            address(vault),
            viewSelectors,
            address(adminModule),
            vault.ROLE_PUBLIC() // Public for view functions
        );
        vm.stopPrank();

        // Set vetoer and bootstrap paramMinDelay
        vm.startPrank(owner);
        IAdminModule(address(vault)).setVetoer(vetoer);

        // Bootstrap paramMinDelay from 0 (constructor default) to 2 days.
        // With paramMinDelay=0 the eta is block.timestamp, so accept works immediately.
        IAdminModule(address(vault)).submitMinDelay(DEFAULT_MIN_DELAY);
        IAdminModule(address(vault)).acceptMinDelay();
        vm.stopPrank();
    }

    // Helper to get admin interface
    function admin() internal view returns (IAdminModule) {
        return IAdminModule(address(vault));
    }

    /* ===== FEE PARAMS TIMELOCK ===== */

    function test_submitFeeParams_creates_pending_with_correct_eta() public {
        uint16 newDepFee = 50; // 0.5%
        uint16 newWitFee = 30; // 0.3%
        address newTreasury = address(0xFEE2);

        uint64 expectedEta = uint64(block.timestamp) + DEFAULT_MIN_DELAY;

        vm.prank(owner);
        admin().submitFeeParams(newDepFee, newWitFee, 0, 0, newTreasury);

        // Verify pending state
        (uint16 dep, uint16 wit, address treas, uint64 eta, bool exists) =
            admin().getPendingFeeParams();
        assertEq(dep, newDepFee, "pendingFee.dep mismatch");
        assertEq(wit, newWitFee, "pendingFee.wit mismatch");
        assertEq(treas, newTreasury, "pendingFee.treasury mismatch");
        assertEq(eta, expectedEta, "pendingFee.eta mismatch");
        assertTrue(exists, "pendingFee should exist");
    }

    function test_acceptFeeParams_succeeds_after_delay() public {
        uint16 newDepFee = 50;
        uint16 newWitFee = 30;
        address newTreasury = address(0xFEE2);

        // Submit
        vm.prank(owner);
        admin().submitFeeParams(newDepFee, newWitFee, 0, 0, newTreasury);

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        // Accept
        vm.prank(owner);
        admin().acceptFeeParams();

        // Verify params updated
        (uint16 actualDep, uint16 actualWit, address actualTreas) = admin().getFeeParams();
        assertEq(actualDep, newDepFee, "depositFeeBps not updated");
        assertEq(actualWit, newWitFee, "withdrawFeeBps not updated");
        assertEq(actualTreas, newTreasury, "treasury not updated");

        // Verify pending cleared
        (,,,, bool exists) = admin().getPendingFeeParams();
        assertFalse(exists, "pendingFee should be cleared");
    }

    function test_acceptFeeParams_reverts_before_eta() public {
        vm.prank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector);

        // Try to accept immediately (before eta)
        vm.prank(owner);
        vm.expectRevert();
        admin().acceptFeeParams();

        // Try to accept 1 second before eta
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY - 1);
        vm.prank(owner);
        vm.expectRevert();
        admin().acceptFeeParams();
    }

    function test_acceptFeeParams_reverts_after_window_expires() public {
        vm.prank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector);

        // Fast forward past eta + PARAM_MAX_WINDOW
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW + 1);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptFeeParams();
    }

    function test_acceptFeeParams_reverts_when_no_pending() public {
        vm.prank(owner);
        vm.expectRevert();
        admin().acceptFeeParams();
    }

    function test_revokeFeeParams_clears_pending() public {
        vm.prank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector);

        // Verify pending exists
        (,,,, bool existsBefore) = admin().getPendingFeeParams();
        assertTrue(existsBefore, "pending should exist before revoke");

        // Revoke
        vm.prank(owner);
        admin().revokeFeeParams();

        // Verify pending cleared
        (,,,, bool existsAfter) = admin().getPendingFeeParams();
        assertFalse(existsAfter, "pending should be cleared after revoke");
    }

    function test_submitFeeParams_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        admin().submitFeeParams(50, 30, 0, 0, feeCollector);
    }

    function test_acceptFeeParams_only_owner() public {
        vm.prank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector);

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        vm.prank(user);
        vm.expectRevert();
        admin().acceptFeeParams();
    }

    function test_revokeFeeParams_only_owner() public {
        vm.prank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector);

        vm.prank(user);
        vm.expectRevert();
        admin().revokeFeeParams();
    }

    /* ===== PERF PARAMS TIMELOCK ===== */

    function test_submitPerfParams_creates_pending_with_correct_eta() public {
        uint256 newPerfRate = 2e17; // 20%
        uint64 newMinInterval = 7200; // 2 hours

        uint64 expectedEta = uint64(block.timestamp) + DEFAULT_MIN_DELAY;

        vm.prank(owner);
        admin().submitPerfParams(newPerfRate, newMinInterval);

        // Verify pending state
        (uint256 rateX, uint64 minInt, uint64 eta, bool exists) = admin().getPendingPerfParams();
        assertEq(rateX, newPerfRate, "pendingPerf.rateX mismatch");
        assertEq(minInt, newMinInterval, "pendingPerf.minInterval mismatch");
        assertEq(eta, expectedEta, "pendingPerf.eta mismatch");
        assertTrue(exists, "pendingPerf should exist");
    }

    function test_submitPerfParams_reverts_if_rate_too_high() public {
        uint256 excessivePerfRate = 6e17; // 60% - exceeds 50% max

        vm.prank(owner);
        vm.expectRevert();
        admin().submitPerfParams(excessivePerfRate, 3600);
    }

    function test_submitPerfParams_accepts_max_rate() public {
        uint256 maxPerfRate = 5e17; // 50% - exactly at max

        vm.prank(owner);
        admin().submitPerfParams(maxPerfRate, 3600);

        (uint256 rateX,,,) = admin().getPendingPerfParams();
        assertEq(rateX, maxPerfRate, "should accept max rate");
    }

    function test_acceptPerfParams_succeeds_after_delay() public {
        uint256 newPerfRate = 2e17;
        uint64 newMinInterval = 7200;

        // Submit
        vm.prank(owner);
        admin().submitPerfParams(newPerfRate, newMinInterval);

        // Fast forward past delay
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        // Accept
        vm.prank(owner);
        admin().acceptPerfParams();

        // Verify params updated
        (uint256 actualRate, uint64 actualInterval,,) = admin().getPerfParams();
        assertEq(actualRate, newPerfRate, "perfRateX not updated");
        assertEq(actualInterval, newMinInterval, "minInterval not updated");

        // Verify pending cleared
        (,,, bool exists) = admin().getPendingPerfParams();
        assertFalse(exists, "pendingPerf should be cleared");
    }

    function test_acceptPerfParams_reverts_before_eta() public {
        vm.prank(owner);
        admin().submitPerfParams(2e17, 7200);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptPerfParams();
    }

    function test_acceptPerfParams_reverts_after_window_expires() public {
        vm.prank(owner);
        admin().submitPerfParams(2e17, 7200);

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW + 1);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptPerfParams();
    }

    function test_revokePerfParams_clears_pending() public {
        vm.prank(owner);
        admin().submitPerfParams(2e17, 7200);

        vm.prank(owner);
        admin().revokePerfParams();

        (,,, bool exists) = admin().getPendingPerfParams();
        assertFalse(exists, "pending should be cleared");
    }

    /* ===== PARAM MIN DELAY TIMELOCK ===== */

    function test_submitMinDelay_creates_pending() public {
        uint64 newDelay = 5 days;
        uint64 expectedEta = uint64(block.timestamp) + DEFAULT_MIN_DELAY;

        vm.prank(owner);
        admin().submitMinDelay(newDelay);

        (uint64 delay, uint64 eta, bool exists) = admin().getPendingMinDelay();
        assertEq(delay, newDelay, "pendingDelay.newDelay mismatch");
        assertEq(eta, expectedEta, "pendingDelay.eta mismatch");
        assertTrue(exists, "pendingDelay should exist");
    }

    function test_acceptMinDelay_updates_delay() public {
        uint64 newDelay = 5 days;

        // Submit
        vm.prank(owner);
        admin().submitMinDelay(newDelay);

        // Fast forward
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);

        // Accept
        vm.prank(owner);
        admin().acceptMinDelay();

        // Verify delay updated
        assertEq(vault.paramMinDelay(), newDelay, "paramMinDelay not updated");

        // Verify pending cleared
        (,, bool exists) = admin().getPendingMinDelay();
        assertFalse(exists, "pendingDelay should be cleared");
    }

    function test_acceptMinDelay_reverts_before_eta() public {
        vm.prank(owner);
        admin().submitMinDelay(5 days);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptMinDelay();
    }

    function test_acceptMinDelay_reverts_after_window() public {
        vm.prank(owner);
        admin().submitMinDelay(5 days);

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW + 1);

        vm.prank(owner);
        vm.expectRevert();
        admin().acceptMinDelay();
    }

    function test_acceptMinDelay_reverts_when_no_pending() public {
        vm.prank(owner);
        vm.expectRevert();
        admin().acceptMinDelay();
    }

    function test_revokeMinDelay_clears_pending() public {
        vm.prank(owner);
        admin().submitMinDelay(5 days);

        vm.prank(owner);
        admin().revokeMinDelay();

        (,, bool exists) = admin().getPendingMinDelay();
        assertFalse(exists, "pendingDelay should be cleared");
    }

    /* ===== VETOER MANAGEMENT ===== */

    function test_setVetoer_updates_address() public {
        address newVetoer = address(0xBEE2);

        vm.prank(owner);
        admin().setVetoer(newVetoer);

        assertEq(vault.vetoer(), newVetoer, "vetoer not updated");
    }

    function test_setVetoer_only_owner() public {
        vm.prank(user);
        vm.expectRevert();
        admin().setVetoer(address(0xBEE2));
    }

    /* ===== EDGE CASES & INTEGRATION ===== */

    function test_multiple_pending_changes_can_coexist() public {
        // Submit all three types of changes
        vm.startPrank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector); // depBps, witBps, penaltyBps, treasury
        admin().submitPerfParams(2e17, 7200);
        admin().submitMinDelay(5 days);
        vm.stopPrank();

        // Verify all exist
        (,,,, bool feeExists) = admin().getPendingFeeParams();
        (,,, bool perfExists) = admin().getPendingPerfParams();
        (,, bool delayExists) = admin().getPendingMinDelay();

        assertTrue(feeExists, "pendingFee should exist");
        assertTrue(perfExists, "pendingPerf should exist");
        assertTrue(delayExists, "pendingDelay should exist");
    }

    function test_accept_within_window_boundary() public {
        vm.prank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector); // depBps, witBps, penaltyBps, treasury

        // Accept at exact eta
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY);
        vm.prank(owner);
        admin().acceptFeeParams();

        (uint16 actualDep,,) = admin().getFeeParams();
        assertEq(actualDep, 50, "should accept at exact eta");
    }

    function test_accept_at_window_end_boundary() public {
        vm.prank(owner);
        admin().submitPerfParams(2e17, 7200);

        // Accept at eta + PARAM_MAX_WINDOW (last valid moment)
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + PARAM_MAX_WINDOW);
        vm.prank(owner);
        admin().acceptPerfParams();

        (uint256 actualRate,,,) = admin().getPerfParams();
        assertEq(actualRate, 2e17, "should accept at window end");
    }

    function test_resubmit_after_revoke() public {
        // Submit and revoke
        vm.startPrank(owner);
        admin().submitFeeParams(50, 30, 0, 0, feeCollector); // depBps, witBps, penaltyBps, treasury
        admin().revokeFeeParams();

        // Resubmit with different params
        admin().submitFeeParams(100, 60, 0, 0, feeCollector); // depBps, witBps, penaltyBps, treasury
        vm.stopPrank();

        // Verify new params are pending
        (uint16 dep, uint16 wit,,,) = admin().getPendingFeeParams();
        assertEq(dep, 100, "should have new deposit fee");
        assertEq(wit, 60, "should have new withdraw fee");
    }
}
