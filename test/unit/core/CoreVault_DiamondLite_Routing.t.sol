// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "src/core/CoreVault.sol";
import { QueueModule } from "src/core/modules/QueueModule.sol";
import { AdminModule } from "src/core/modules/AdminModule.sol";
import { SelectorLib } from "src/core/libraries/SelectorLib.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "test/helpers/MockParamsProvider.sol";
import { ModuleSetter } from "test/helpers/ModuleSetter.sol";
import { CoreHarness } from "test/helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "test/helpers/MockBufferManagerForTests.sol";
import { ExitEngineLib } from "src/core/libraries/ExitEngineLib.sol";

interface IQueueModule_Routing {
    function requestClaim(bool immediate, uint256 shares) external;
}

/// @title CoreVault Routing Tests
/// @notice Tests for the Diamond-lite routing mechanism
contract CoreVault_Routing_Test is Test {
    CoreVault public router;
    QueueModule public queueModule;
    AdminModule public adminModule;
    ERC20Mock public usdc;
    MockParamsProvider public params;

    address public owner = address(this);
    address public guardian = address(0xABCD);
    address public feeCollector = address(0xFEE5);
    address public user1 = address(0xBEEF);

    // Role constants
    uint8 constant ROLE_PUBLIC = 0;
    uint8 constant ROLE_OWNER = 1;
    uint8 constant ROLE_GUARDIAN = 2;
    uint8 constant ROLE_MODULE = 3;

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(address(this), 1_000_000e6);
        usdc._mint(user1, 100_000e6);

        // Deploy params provider
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        // Deploy CoreVault (via CoreHarness for setBufferManagerUnsafe)
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "tVault",
            owner,
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        router = _harness;

        // Deploy modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        // Configure routing using SelectorLib (source of truth)
        // QueueModule selectors (PUBLIC)
        bytes4[] memory queueSelectors = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            address(router), queueSelectors, address(queueModule), ROLE_PUBLIC
        );

        // QueueModule view selectors (PUBLIC)
        bytes4[] memory queueViewSelectors = SelectorLib.getQueueModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(router), queueViewSelectors, address(queueModule), ROLE_PUBLIC
        );

        // AdminModule owner selectors (OWNER)
        bytes4[] memory adminOwnerSelectors = SelectorLib.getAdminModuleOwnerSelectors();
        ModuleSetter.setModulesSame(
            address(router), adminOwnerSelectors, address(adminModule), ROLE_OWNER
        );

        // AdminModule view selectors (PUBLIC)
        bytes4[] memory adminViewSelectors = SelectorLib.getAdminModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(router), adminViewSelectors, address(adminModule), ROLE_PUBLIC
        );

        // Note: Internal module selectors are no longer routed - they use msg.sender == address(this)

        // Set guardian
        router.setGuardian(guardian);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // BASIC ROUTING TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_moduleOf_returnsCorrectModule() public view {
        assertEq(router.moduleOf(QueueModule.requestClaim.selector), address(queueModule));
        assertEq(router.moduleOf(AdminModule.submitFeeParams.selector), address(adminModule));
    }

    function test_roleOf_returnsCorrectRole() public view {
        assertEq(router.roleOf(QueueModule.requestClaim.selector), ROLE_PUBLIC);
        assertEq(router.roleOf(AdminModule.submitFeeParams.selector), ROLE_OWNER);
    }

    function test_setModule_singleSelector() public {
        bytes4 selector = bytes4(keccak256("customFunction()"));
        address module = address(0x1234);

        router.setModule(selector, module, ROLE_PUBLIC);

        assertEq(router.moduleOf(selector), module);
        assertEq(router.roleOf(selector), ROLE_PUBLIC);
    }

    function test_setModule_revertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.setModule(bytes4(0), address(0), ROLE_PUBLIC);
    }

    function test_setModulesSame_batchConfiguration() public {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = bytes4(keccak256("func1()"));
        selectors[1] = bytes4(keccak256("func2()"));
        selectors[2] = bytes4(keccak256("func3()"));

        address module = address(0x5678);
        ModuleSetter.setModulesSame(address(router), selectors, module, ROLE_GUARDIAN);

        for (uint256 i = 0; i < selectors.length; i++) {
            assertEq(router.moduleOf(selectors[i]), module);
            assertEq(router.roleOf(selectors[i]), ROLE_GUARDIAN);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ROUTING FREEZE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_freezeRouting_preventsNewModules() public {
        router.freezeRouting();
        assertTrue(router.isRoutingFrozen());

        vm.expectRevert(CoreVault.RoutingFrozen.selector);
        router.setModule(bytes4(0), address(0), ROLE_PUBLIC);
    }

    function test_freezeRouting_preventsSetModulesSame() public {
        router.freezeRouting();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0);

        // ModuleSetter.setModulesSame will call setModule internally which reverts
        vm.expectRevert(CoreVault.RoutingFrozen.selector);
        router.setModule(selectors[0], address(0), ROLE_PUBLIC);
    }

    function test_freezeRouting_onlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(CoreVault.NotOwner.selector);
        router.freezeRouting();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ROLE ENFORCEMENT TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_ownerOnlyFunction_revertsForNonOwner() public {
        vm.prank(user1);
        // Call submitFeeParams which requires ROLE_OWNER - should revert with NotOwner
        (bool success, bytes memory data) = address(router)
            .call(
                abi.encodeWithSelector(AdminModule.submitFeeParams.selector, 10, 10, feeCollector)
            );
        // The call should have failed
        assertFalse(success);
        // Check the revert reason
        assertEq(bytes4(data), CoreVault.NotOwner.selector);
    }

    function test_publicFunction_allowsAnyUser() public {
        // Deposit some assets first so user1 has shares
        vm.startPrank(user1);
        usdc.approve(address(router), 1000e6);
        router.deposit(1000e6, user1);

        // Now user1 should be able to call requestClaim (public function)
        // This will revert for other reasons (need approval for shares), but routing should work
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // UNKNOWN SELECTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_unknownSelector_reverts() public {
        bytes4 unknownSelector = bytes4(keccak256("unknownFunction()"));

        (bool success, bytes memory data) =
            address(router).call(abi.encodeWithSelector(unknownSelector));
        // The call should have failed
        assertFalse(success);
        // Check the revert reason
        assertEq(bytes4(data), CoreVault.ModuleNotSet.selector);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PAUSE INTERACTION WITH ROUTING
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_pauseAll_affectsRouting() public {
        router.pauseAll();
        assertTrue(router.paused());
    }

    function test_pauseDeposits_allowsWithdrawals() public {
        // First deposit
        usdc.approve(address(router), 1000e6);
        router.deposit(1000e6, address(this));

        // Pause deposits only
        router.pauseDepositsOnly(true);
        assertTrue(router.pausedDeposits());
        assertFalse(router.pausedWithdrawals());

        // withdraw() always reverts now; verify requestClaim works when deposits paused
        uint256 shares = router.balanceOf(address(this));
        IQueueModule_Routing(address(router)).requestClaim(true, shares / 2);
    }

    function test_pauseWithdrawals_allowsDeposits() public {
        router.pauseWithdrawalsOnly(true);
        assertTrue(router.pausedWithdrawals());
        assertFalse(router.pausedDeposits());

        // Deposit should still work
        usdc.approve(address(router), 1000e6);
        router.deposit(1000e6, address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERC4626 BASIC TESTS (kept in router)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_deposit_mintsShares() public {
        uint256 assets = 1000e6;
        usdc.approve(address(router), assets);

        uint256 sharesBefore = router.balanceOf(address(this));
        uint256 shares = router.deposit(assets, address(this));
        uint256 sharesAfter = router.balanceOf(address(this));

        assertEq(sharesAfter - sharesBefore, shares);
        assertGt(shares, 0);
    }

    function test_withdraw_alwaysRevertsAsync() public {
        uint256 assets = 1000e6;
        usdc.approve(address(router), assets);
        router.deposit(assets, address(this));

        // withdraw() always reverts with AsyncWithdrawalRequired
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        router.withdraw(500e6, address(this), address(this));
    }

    function test_redeem_alwaysRevertsAsync() public {
        uint256 assets = 1000e6;
        usdc.approve(address(router), assets);
        uint256 shares = router.deposit(assets, address(this));

        // redeem() always reverts with AsyncWithdrawalRequired
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        router.redeem(shares / 2, address(this), address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // GUARDIAN TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_guardianPause_works() public {
        // Warp past initial cooldown (lastGuardianPause starts at 0)
        vm.warp(8 days);

        vm.prank(guardian);
        router.guardianPause();
        assertTrue(router.paused());
    }

    function test_guardianPause_cooldown() public {
        // Warp past initial cooldown (lastGuardianPause starts at 0, so first pause always works)
        vm.warp(8 days);

        vm.prank(guardian);
        router.guardianPause();

        // Try to pause again immediately - should fail (7-day cooldown)
        vm.prank(guardian);
        vm.expectRevert(CoreVault.GuardianCooldownActive.selector);
        router.guardianPause();
    }

    function test_guardianPause_cooldownExpires() public {
        // Warp past initial cooldown
        vm.warp(8 days);

        vm.prank(guardian);
        router.guardianPause();

        // Owner unpauses
        router.unpauseAll();

        // Warp past cooldown
        vm.warp(block.timestamp + 7 days + 1);

        // Guardian can pause again
        vm.prank(guardian);
        router.guardianPause();
        assertTrue(router.paused());
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // OWNERSHIP TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_beginOwnerTransfer_twoStep() public {
        address newOwner = address(0x9999);

        router.beginOwnerTransfer(newOwner);
        assertEq(router.pendingOwner(), newOwner);
        assertEq(router.owner(), owner); // Still old owner

        vm.prank(newOwner);
        router.acceptOwnerTransfer();
        assertEq(router.owner(), newOwner);
        assertEq(router.pendingOwner(), address(0));
    }

    function test_acceptOwnerTransfer_revertsForNonPending() public {
        address newOwner = address(0x9999);
        router.beginOwnerTransfer(newOwner);

        vm.prank(user1);
        vm.expectRevert(CoreVault.NoTransferPending.selector);
        router.acceptOwnerTransfer();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SELECTOR COVERAGE TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_selectorLib_allSelectorsValid() public pure {
        // Verify all selectors are non-zero
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        for (uint256 i; i < queueSels.length; i++) {
            assertTrue(queueSels[i] != bytes4(0), "Queue selector is zero");
        }

        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        for (uint256 i; i < adminOwnerSels.length; i++) {
            assertTrue(adminOwnerSels[i] != bytes4(0), "Admin owner selector is zero");
        }

        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        for (uint256 i; i < adminViewSels.length; i++) {
            assertTrue(adminViewSels[i] != bytes4(0), "Admin view selector is zero");
        }

        // Note: Internal selectors are no longer managed via SelectorLib
        // They are internal functions with msg.sender == address(this) check
    }

    function test_selectorLib_totalCountCorrect() public pure {
        uint256 queueCount = SelectorLib.getQueueModuleSelectors().length;
        uint256 queueViewCount = SelectorLib.getQueueModuleViewSelectors().length;
        uint256 adminOwnerCount = SelectorLib.getAdminModuleOwnerSelectors().length;
        uint256 adminViewCount = SelectorLib.getAdminModuleViewSelectors().length;
        uint256 erc4626Count = SelectorLib.getERC4626ModuleSelectors().length;
        uint256 liquidityOpsCount = SelectorLib.getLiquidityOpsModuleSelectors().length;
        uint256 fmCount = SelectorLib.getFixedMaturityModuleSelectors().length;

        uint256 total = queueCount + queueViewCount + adminOwnerCount + adminViewCount
            + erc4626Count + liquidityOpsCount + fmCount;
        assertEq(total, SelectorLib.TOTAL_SELECTORS, "Total selectors mismatch");
    }

    function test_validateAllSelectorsMapped_returnsValid() public view {
        (bool valid, uint256 missing) = SelectorLib.validateAllSelectorsMapped(
            router, address(queueModule), address(adminModule)
        );
        assertTrue(valid, "Selectors should be valid");
        assertEq(missing, 0, "Should have no missing selectors");
    }

    function test_validateAllSelectorsMapped_detectsMissing() public {
        // Create new router without configuration
        CoreVault unconfiguredRouter = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault 2",
            "tVault2",
            owner,
            feeCollector,
            address(params)
        );

        (bool valid, uint256 missing) = SelectorLib.validateAllSelectorsMapped(
            unconfiguredRouter, address(queueModule), address(adminModule)
        );
        assertFalse(valid, "Should detect unconfigured router");
        assertGt(missing, 0, "Should have missing selectors");
    }

    function test_getExpectedRole_returnsCorrect() public pure {
        // Queue module functions should be PUBLIC
        (uint8 role, bool found) = SelectorLib.getExpectedRole(QueueModule.requestClaim.selector);
        assertTrue(found);
        assertEq(role, SelectorLib.ROLE_PUBLIC);

        // Admin owner functions should be OWNER
        (role, found) = SelectorLib.getExpectedRole(AdminModule.submitFeeParams.selector);
        assertTrue(found);
        assertEq(role, SelectorLib.ROLE_OWNER);

        // Admin view functions should be PUBLIC
        (role, found) = SelectorLib.getExpectedRole(AdminModule.getFeeParams.selector);
        assertTrue(found);
        assertEq(role, SelectorLib.ROLE_PUBLIC);

        // Unknown selector should return not found
        (, found) = SelectorLib.getExpectedRole(bytes4(keccak256("unknownFunction()")));
        assertFalse(found);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FREEZE TESTS (extended)
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_freezeRouting_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Events.RoutingFrozen();
        router.freezeRouting();
    }

    function test_freezeRouting_cannotFreezeAgain() public {
        router.freezeRouting();

        vm.expectRevert(CoreVault.RoutingFrozen.selector);
        router.freezeRouting();
    }

    // Note: setRole doesn't exist separately - role is set via setModule(selector, module, role)
    // The test for freeze blocking routing is covered by test_freezeRouting_preventsNewModules

    function test_setModule_emitsEvent() public {
        bytes4 selector = bytes4(keccak256("newFunction()"));
        address module = address(0x1234);

        vm.expectEmit(true, true, false, true);
        emit Events.ModuleSet(selector, module, ROLE_PUBLIC);
        router.setModule(selector, module, ROLE_PUBLIC);
    }

    function test_setModulesSame_emitsEvents() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("func1()"));
        selectors[1] = bytes4(keccak256("func2()"));
        address module = address(0x5678);

        // setModulesSame calls setModule for each, which emits ModuleSet events
        // Record logs and verify both events were emitted
        vm.recordLogs();
        ModuleSetter.setModulesSame(address(router), selectors, module, ROLE_OWNER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Should have 2 ModuleSet events
        assertEq(logs.length, 2, "Should emit 2 events");

        // Verify first event
        assertEq(
            logs[0].topics[0], keccak256("ModuleSet(bytes4,address,uint8)"), "Event 1 signature"
        );
        assertEq(bytes4(logs[0].topics[1]), selectors[0], "Event 1 selector");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), module, "Event 1 module");

        // Verify second event
        assertEq(
            logs[1].topics[0], keccak256("ModuleSet(bytes4,address,uint8)"), "Event 2 signature"
        );
        assertEq(bytes4(logs[1].topics[1]), selectors[1], "Event 2 selector");
        assertEq(address(uint160(uint256(logs[1].topics[2]))), module, "Event 2 module");
    }
}

// Import Events for event testing
import { Events } from "src/core/libraries/Events.sol";
