// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { CoreVault } from "../../src/core/CoreVault.sol";
import { AdminModule } from "../../src/core/modules/AdminModule.sol";
import { QueueModule } from "../../src/core/modules/QueueModule.sol";
import { IAdminModule } from "../../src/interfaces/IAdminModule.sol";
import { StrategyRouter } from "../../src/core/modules/StrategyRouter.sol";
import { BufferManager } from "../../src/core/modules/BufferManager.sol";
import { StrategyHealthRegistry } from "../../src/core/modules/StrategyHealthRegistry.sol";
import { IStrategyHealthRegistry } from "../../src/interfaces/IStrategyHealthRegistry.sol";
import { GlobalConfig } from "../../src/core/config/GlobalConfig.sol";
import { FeeCollector } from "../../src/core/modules/FeeCollector.sol";
import { SelectorLib } from "../../src/core/libraries/SelectorLib.sol";
import { IBufferManager } from "../../src/interfaces/IBufferManager.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title RolesTimelockInvariants
 * @notice Comprehensive invariant and unit tests for role-based access control
 * @dev Tests that:
 *      - All critical selectors require ROLE_OWNER
 *      - Guardian can only pause and mark strategies DEGRADED/BROKEN (not OK)
 *      - Vetoer can only cancel/revoke pending changes
 *      - FeeCollector governor is immutable and set to ROOT_TIMELOCK
 *      - No deployer roles remain after sealing
 */
contract RolesTimelockInvariants is Test {
    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════
    uint8 constant ROLE_PUBLIC = 0;
    uint8 constant ROLE_OWNER = 1;
    uint8 constant ROLE_GUARDIAN = 2;
    uint8 constant ROLE_OWNER_OR_GUARDIAN = 3;
    uint8 constant ROLE_MODULE = 4;

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════════
    address ROOT_TIMELOCK;
    address SAFE_GUARDIAN;
    address SAFE_VETO;
    address DEPLOYER;
    address ATTACKER;
    address TREASURY;
    address OPS;
    address SAFETY_RESERVE;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONTRACTS
    // ═══════════════════════════════════════════════════════════════════════════════
    CoreVault vault;
    AdminModule adminModule;
    QueueModule queueModule;
    StrategyRouter router;
    BufferManager buffer;
    StrategyHealthRegistry healthReg;
    GlobalConfig globalConfig;
    FeeCollector feeCollector;
    MockUSDC usdc;

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════════
    function setUp() public {
        // Setup addresses
        DEPLOYER = address(this);
        ROOT_TIMELOCK = makeAddr("ROOT_TIMELOCK");
        SAFE_GUARDIAN = makeAddr("SAFE_GUARDIAN");
        SAFE_VETO = makeAddr("SAFE_VETO");
        ATTACKER = makeAddr("ATTACKER");
        TREASURY = makeAddr("TREASURY");
        OPS = makeAddr("OPS");
        SAFETY_RESERVE = makeAddr("SAFETY_RESERVE");

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy FeeCollector with ROOT_TIMELOCK as immutable governor
        feeCollector = new FeeCollector(
            ROOT_TIMELOCK, // governor (IMMUTABLE!)
            TREASURY,
            OPS,
            SAFETY_RESERVE,
            7000, // treasuryBps
            100, // safetyReserveBps
            3000 // opsMaxBps
        );

        // Deploy GlobalConfig
        globalConfig = new GlobalConfig(
            ROOT_TIMELOCK, // governor
            50, // depositBps
            100, // withdrawBps
            2000, // perfBps
            1 days, // lockPeriod
            10, // maxActions
            500, // maxNavDelta
            1 hours, // cooldown
            1 hours // staleness
        );

        // Deploy HealthRegistry
        healthReg = new StrategyHealthRegistry(ROOT_TIMELOCK, SAFE_GUARDIAN);

        // Deploy CoreVault
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "TV",
            DEPLOYER, // temporary owner
            address(feeCollector),
            address(globalConfig)
        );

        // Deploy modules
        adminModule = new AdminModule();
        queueModule = new QueueModule();

        // Deploy components
        IBufferManager.BufferConfig memory bufferConfig = IBufferManager.BufferConfig({
            targetHotBps: 300,
            minHotBps: 200,
            targetWarmBps: 700,
            maxWarmBps: 1000,
            opsReserveTargetBps: 100,
            maxWarmSlippageBps: 50,
            asset: address(usdc),
            warmAdapter: address(0),
            twapWindowSec: 0,
            paused: true
        });
        buffer = new BufferManager(DEPLOYER, address(vault), bufferConfig);
        router = new StrategyRouter(DEPLOYER, address(vault), address(globalConfig));

        // Wire modules using SelectorLib
        _wireModules();

        // Set ecosystem
        vm.prank(DEPLOYER);
        IAdminModule(address(vault))
            .setEcosystem(
                IAdminModule.EcosystemConfig({
                    bufferManager: address(buffer),
                    strategyRouter: address(router),
                    healthRegistry: address(healthReg),
                    incentives: address(0),
                    guardian: SAFE_GUARDIAN,
                    vetoer: SAFE_VETO
                })
            );

        // Seal: freeze routing and enable components timelock
        vm.startPrank(DEPLOYER);
        vault.freezeRouting();
        IAdminModule(address(vault)).enableComponentsTimelock();
        vm.stopPrank();

        // Transfer ownership to ROOT_TIMELOCK
        vm.prank(DEPLOYER);
        vault.beginOwnerTransfer(ROOT_TIMELOCK);
        vm.prank(ROOT_TIMELOCK);
        vault.acceptOwnerTransfer();

        vm.prank(DEPLOYER);
        buffer.transferOwnership(ROOT_TIMELOCK);

        vm.prank(DEPLOYER);
        router.transferOwnership(ROOT_TIMELOCK);
    }

    function _wireModules() internal {
        // Get selectors from SelectorLib
        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        bytes4[] memory queueViewSels = SelectorLib.getQueueModuleViewSelectors();
        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();

        // Wire QueueModule (PUBLIC)
        address[] memory queueModules = new address[](queueSels.length);
        uint8[] memory queueRoles = new uint8[](queueSels.length);
        for (uint256 i = 0; i < queueSels.length; i++) {
            queueModules[i] = address(queueModule);
            queueRoles[i] = ROLE_PUBLIC;
        }
        vault.setModulesBatch(queueSels, queueModules, queueRoles);

        // Wire QueueModule views (PUBLIC)
        address[] memory queueViewModules = new address[](queueViewSels.length);
        uint8[] memory queueViewRoles = new uint8[](queueViewSels.length);
        for (uint256 i = 0; i < queueViewSels.length; i++) {
            queueViewModules[i] = address(queueModule);
            queueViewRoles[i] = ROLE_PUBLIC;
        }
        vault.setModulesBatch(queueViewSels, queueViewModules, queueViewRoles);

        // Wire AdminModule owner functions (OWNER)
        address[] memory adminOwnerModules = new address[](adminOwnerSels.length);
        uint8[] memory adminOwnerRoles = new uint8[](adminOwnerSels.length);
        for (uint256 i = 0; i < adminOwnerSels.length; i++) {
            adminOwnerModules[i] = address(adminModule);
            adminOwnerRoles[i] = ROLE_OWNER;
        }
        vault.setModulesBatch(adminOwnerSels, adminOwnerModules, adminOwnerRoles);

        // Wire AdminModule view functions (PUBLIC)
        address[] memory adminViewModules = new address[](adminViewSels.length);
        uint8[] memory adminViewRoles = new uint8[](adminViewSels.length);
        for (uint256 i = 0; i < adminViewSels.length; i++) {
            adminViewModules[i] = address(adminModule);
            adminViewRoles[i] = ROLE_PUBLIC;
        }
        vault.setModulesBatch(adminViewSels, adminViewModules, adminViewRoles);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 1: SELECTOR ROLE VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice All AdminModule owner selectors MUST have ROLE_OWNER
    function test_allAdminOwnerSelectorsRequireOwner() public view {
        bytes4[] memory selectors = SelectorLib.getAdminModuleOwnerSelectors();

        for (uint256 i = 0; i < selectors.length; i++) {
            uint8 role = vault.roleOf(selectors[i]);
            assertEq(
                role,
                ROLE_OWNER,
                string(
                    abi.encodePacked(
                        "AdminModule selector ", vm.toString(i), " must require ROLE_OWNER"
                    )
                )
            );
        }
    }

    /// @notice Specific critical selectors must have ROLE_OWNER
    function test_criticalSelectorsRequireOwner() public view {
        // These are the most dangerous functions
        bytes4[] memory criticalSelectors = new bytes4[](10);
        criticalSelectors[0] = AdminModule.setParams.selector;
        criticalSelectors[1] = AdminModule.setBufferManager.selector;
        criticalSelectors[2] = AdminModule.setRouter.selector;
        criticalSelectors[3] = AdminModule.setHealthRegistry.selector;
        criticalSelectors[4] = AdminModule.setIncentives.selector;
        criticalSelectors[5] = AdminModule.setFeeCollector.selector;
        criticalSelectors[6] = AdminModule.setVetoer.selector;
        criticalSelectors[7] = AdminModule.setEcosystem.selector;
        criticalSelectors[8] = AdminModule.freezeParams.selector;
        criticalSelectors[9] = AdminModule.enableComponentsTimelock.selector;

        string[10] memory names = [
            "setParams",
            "setBufferManager",
            "setRouter",
            "setHealthRegistry",
            "setIncentives",
            "setFeeCollector",
            "setVetoer",
            "setEcosystem",
            "freezeParams",
            "enableComponentsTimelock"
        ];

        for (uint256 i = 0; i < criticalSelectors.length; i++) {
            assertEq(
                vault.roleOf(criticalSelectors[i]),
                ROLE_OWNER,
                string(abi.encodePacked(names[i], " MUST require ROLE_OWNER"))
            );
        }
    }

    /// @notice QueueModule selectors must be PUBLIC
    function test_queueSelectorsArePublic() public view {
        bytes4[] memory selectors = SelectorLib.getQueueModuleSelectors();

        for (uint256 i = 0; i < selectors.length; i++) {
            assertEq(vault.roleOf(selectors[i]), ROLE_PUBLIC, "QueueModule selector must be PUBLIC");
        }
    }

    /// @notice AdminModule view selectors must be PUBLIC
    function test_adminViewSelectorsArePublic() public view {
        bytes4[] memory selectors = SelectorLib.getAdminModuleViewSelectors();

        for (uint256 i = 0; i < selectors.length; i++) {
            assertEq(
                vault.roleOf(selectors[i]), ROLE_PUBLIC, "AdminModule view selector must be PUBLIC"
            );
        }
    }

    /// @notice Use SelectorLib.validateAllSelectorsMapped for complete validation
    function test_selectorLibValidation() public view {
        (bool valid, uint256 missingCount) = SelectorLib.validateAllSelectorsMapped(
            vault, address(queueModule), address(adminModule)
        );
        assertTrue(
            valid, string(abi.encodePacked("Missing ", vm.toString(missingCount), " selectors"))
        );
        assertEq(missingCount, 0, "All selectors must be correctly mapped");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 2: OWNERSHIP INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice CoreVault owner must be ROOT_TIMELOCK after setup
    function test_vaultOwnerIsTimelock() public view {
        assertEq(vault.owner(), ROOT_TIMELOCK, "CoreVault owner must be ROOT_TIMELOCK");
    }

    /// @notice BufferManager owner must be ROOT_TIMELOCK
    function test_bufferOwnerIsTimelock() public view {
        assertEq(buffer.owner(), ROOT_TIMELOCK, "BufferManager owner must be ROOT_TIMELOCK");
    }

    /// @notice StrategyRouter owner must be ROOT_TIMELOCK
    function test_routerOwnerIsTimelock() public view {
        assertEq(router.owner(), ROOT_TIMELOCK, "StrategyRouter owner must be ROOT_TIMELOCK");
    }

    /// @notice GlobalConfig governor must be ROOT_TIMELOCK
    function test_globalConfigGovernorIsTimelock() public view {
        assertEq(
            globalConfig.governor(), ROOT_TIMELOCK, "GlobalConfig governor must be ROOT_TIMELOCK"
        );
    }

    /// @notice HealthRegistry owner must be ROOT_TIMELOCK
    function test_healthRegistryOwnerIsTimelock() public view {
        assertEq(healthReg.owner(), ROOT_TIMELOCK, "HealthRegistry owner must be ROOT_TIMELOCK");
    }

    /// @notice Deployer should not be vault owner after sealing
    function test_deployerNotVaultOwner() public view {
        assertTrue(vault.owner() != DEPLOYER, "Deployer should not be vault owner");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 3: FEECOLLECTOR GOVERNOR IMMUTABILITY
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice FeeCollector governor must be ROOT_TIMELOCK (immutable)
    function test_feeCollectorGovernorIsTimelock() public view {
        assertEq(
            feeCollector.governor(), ROOT_TIMELOCK, "FeeCollector governor must be ROOT_TIMELOCK"
        );
    }

    /// @notice FeeCollector has no setGovernor function (governor is immutable)
    function test_feeCollectorGovernorIsImmutable() public {
        // Try to call a non-existent setGovernor function
        bytes4 setGovernorSelector = bytes4(keccak256("setGovernor(address)"));
        (bool success,) =
            address(feeCollector).call(abi.encodeWithSelector(setGovernorSelector, ATTACKER));
        assertFalse(success, "FeeCollector should NOT have setGovernor function");

        // Verify governor hasn't changed
        assertEq(feeCollector.governor(), ROOT_TIMELOCK, "Governor must remain ROOT_TIMELOCK");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 4: GUARDIAN RESTRICTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Guardian CAN call guardianPause (after cooldown)
    function test_guardianCanPause() public {
        // Skip guardian cooldown period (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(SAFE_GUARDIAN);
        vault.guardianPause();
        assertTrue(vault.paused(), "Guardian should be able to pause");
    }

    /// @notice Guardian CANNOT call unpauseAll (owner only)
    function test_guardianCannotUnpause() public {
        // Skip guardian cooldown period (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        // First pause via guardian
        vm.prank(SAFE_GUARDIAN);
        vault.guardianPause();

        // Guardian cannot unpause
        vm.prank(SAFE_GUARDIAN);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.unpauseAll();
    }

    /// @notice Guardian CANNOT submit fee params
    function test_guardianCannotSubmitFeeParams() public {
        vm.prank(SAFE_GUARDIAN);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, TREASURY);
    }

    /// @notice Guardian CANNOT call setEcosystem
    function test_guardianCannotSetEcosystem() public {
        vm.prank(SAFE_GUARDIAN);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault))
            .setEcosystem(
                IAdminModule.EcosystemConfig({
                    bufferManager: address(0x123),
                    strategyRouter: address(0x456),
                    healthRegistry: address(0),
                    incentives: address(0),
                    guardian: address(0x789),
                    vetoer: address(0)
                })
            );
    }

    /// @notice Guardian CANNOT call setGuardian
    function test_guardianCannotSetGuardian() public {
        vm.prank(SAFE_GUARDIAN);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.setGuardian(ATTACKER);
    }

    /// @notice Guardian CAN mark strategy DEGRADED in HealthRegistry
    function test_guardianCanMarkStrategyDegraded() public {
        address mockStrategy = makeAddr("mockStrategy");

        vm.prank(SAFE_GUARDIAN);
        healthReg.setStrategyState(
            mockStrategy, IStrategyHealthRegistry.StrategyState.DEGRADED, "test incident"
        );

        assertEq(
            uint8(healthReg.getStrategyState(mockStrategy)),
            uint8(IStrategyHealthRegistry.StrategyState.DEGRADED),
            "Guardian should be able to mark DEGRADED"
        );
    }

    /// @notice Guardian CAN mark strategy BROKEN in HealthRegistry
    function test_guardianCanMarkStrategyBroken() public {
        address mockStrategy = makeAddr("mockStrategy");

        vm.prank(SAFE_GUARDIAN);
        healthReg.setStrategyState(
            mockStrategy, IStrategyHealthRegistry.StrategyState.BROKEN, "critical incident"
        );

        assertEq(
            uint8(healthReg.getStrategyState(mockStrategy)),
            uint8(IStrategyHealthRegistry.StrategyState.BROKEN),
            "Guardian should be able to mark BROKEN"
        );
    }

    /// @notice Guardian CANNOT restore strategy to OK (only owner can)
    function test_guardianCannotRestoreStrategyToOK() public {
        address mockStrategy = makeAddr("mockStrategy");

        // First mark as BROKEN
        vm.prank(SAFE_GUARDIAN);
        healthReg.setStrategyState(
            mockStrategy, IStrategyHealthRegistry.StrategyState.BROKEN, "incident"
        );

        // Guardian cannot restore to OK
        vm.prank(SAFE_GUARDIAN);
        vm.expectRevert(StrategyHealthRegistry.GuardianCannotMarkOK.selector);
        healthReg.setStrategyState(
            mockStrategy, IStrategyHealthRegistry.StrategyState.OK, "restored"
        );
    }

    /// @notice Only owner (ROOT_TIMELOCK) CAN restore strategy to OK
    function test_onlyOwnerCanRestoreStrategyToOK() public {
        address mockStrategy = makeAddr("mockStrategy");

        // First mark as BROKEN via guardian
        vm.prank(SAFE_GUARDIAN);
        healthReg.setStrategyState(
            mockStrategy, IStrategyHealthRegistry.StrategyState.BROKEN, "incident"
        );

        // Owner (ROOT_TIMELOCK) can restore to OK
        vm.prank(ROOT_TIMELOCK);
        healthReg.setStrategyState(
            mockStrategy, IStrategyHealthRegistry.StrategyState.OK, "incident resolved"
        );

        assertEq(
            uint8(healthReg.getStrategyState(mockStrategy)),
            uint8(IStrategyHealthRegistry.StrategyState.OK),
            "Owner should restore to OK"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 5: VETOER RESTRICTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Vetoer CANNOT submit fee params
    function test_vetoerCannotSubmitFeeParams() public {
        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, TREASURY);
    }

    /// @notice Vetoer CANNOT call setEcosystem
    function test_vetoerCannotSetEcosystem() public {
        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault))
            .setEcosystem(
                IAdminModule.EcosystemConfig({
                    bufferManager: address(0x123),
                    strategyRouter: address(0x456),
                    healthRegistry: address(0),
                    incentives: address(0),
                    guardian: address(0x789),
                    vetoer: address(0)
                })
            );
    }

    /// @notice Vetoer CANNOT pause
    function test_vetoerCannotPause() public {
        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseAll();
    }

    /// @notice Vetoer CANNOT call revoke directly on vault (only via timelock cancellation)
    /// @dev Per GOVERNANCE.md: SAFE_VETO can only "Cancel pending timelock operations"
    /// The vetoer operates on the TimelockController, not directly on vault functions
    function test_vetoerCannotRevokeDirectly_feeParams() public {
        // First, owner submits fee params
        vm.prank(ROOT_TIMELOCK);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, TREASURY);

        // Vetoer CANNOT call revoke directly - blocked by ROLE_OWNER routing
        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).revokeFeeParams();
    }

    /// @notice Vetoer CANNOT call revoke directly on vault
    function test_vetoerCannotRevokeDirectly_perfParams() public {
        vm.prank(ROOT_TIMELOCK);
        IAdminModule(address(vault)).submitPerfParams(1e17, 7 days);

        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).revokePerfParams();
    }

    /// @notice Vetoer CANNOT call revoke directly on vault
    function test_vetoerCannotRevokeDirectly_bufferManager() public {
        address newBuffer = makeAddr("newBuffer");
        vm.prank(ROOT_TIMELOCK);
        IAdminModule(address(vault)).submitBufferManager(newBuffer);

        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).revokeBufferManager();
    }

    /// @notice Vetoer CANNOT call revoke directly on vault
    function test_vetoerCannotRevokeDirectly_router() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(ROOT_TIMELOCK);
        IAdminModule(address(vault)).submitRouter(newRouter);

        vm.prank(SAFE_VETO);
        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).revokeRouter();
    }

    /// @notice Owner CAN revoke pending changes
    function test_ownerCanRevokePending() public {
        // Get current buffer manager
        address currentBuffer = address(vault.bufferManager());

        // Owner submits new buffer manager
        address newBuffer = makeAddr("newBuffer");
        vm.prank(ROOT_TIMELOCK);
        IAdminModule(address(vault)).submitBufferManager(newBuffer);

        // Owner can revoke
        vm.prank(ROOT_TIMELOCK);
        IAdminModule(address(vault)).revokeBufferManager();

        // Verify ACTIVE buffer manager is UNCHANGED
        assertEq(
            address(vault.bufferManager()),
            currentBuffer,
            "Revoke must NOT change active buffer manager"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 6: ROUTING FREEZE INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Routing must be frozen after deployment
    function test_routingIsFrozen() public view {
        assertTrue(vault.isRoutingFrozen(), "Routing must be frozen");
    }

    /// @notice Components timelock must be enabled
    function test_componentsTimelockEnabled() public view {
        assertTrue(
            IAdminModule(address(vault)).isComponentsTimelocked(),
            "Components timelock must be enabled"
        );
    }

    /// @notice Cannot change routing after freeze
    function test_cannotChangeRoutingAfterFreeze() public {
        vm.prank(ROOT_TIMELOCK);
        vm.expectRevert(CoreVault.RoutingFrozen.selector);
        vault.setModule(bytes4(0x12345678), address(0x123), ROLE_PUBLIC);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 7: ATTACKER FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Random attacker cannot call vault owner functions
    function testFuzz_attackerCannotCallVaultOwnerFunctions(address attacker) public {
        vm.assume(attacker != ROOT_TIMELOCK);
        vm.assume(attacker != address(0));
        vm.assume(attacker != SAFE_GUARDIAN); // Guardian has limited access

        vm.startPrank(attacker);

        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.setGuardian(attacker);

        vm.expectRevert(CoreVault.NotOwner.selector);
        vault.pauseAll();

        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).submitFeeParams(100, 100, 0, 0, attacker);

        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).setFeeCollector(attacker);

        vm.expectRevert(CoreVault.NotOwner.selector);
        IAdminModule(address(vault)).setVetoer(attacker);

        vm.stopPrank();
    }

    /// @notice Random attacker cannot call router owner functions
    function testFuzz_attackerCannotCallRouterOwnerFunctions(address attacker) public {
        vm.assume(attacker != ROOT_TIMELOCK);
        vm.assume(attacker != address(0));

        vm.startPrank(attacker);

        // StrategyRouter uses require(msg.sender == owner, "not-owner")
        vm.expectRevert("not-owner");
        router.setCore(attacker);

        vm.expectRevert("not-owner");
        router.setParamsProvider(attacker);

        vm.stopPrank();
    }

    /// @notice Random attacker cannot call buffer owner functions
    function testFuzz_attackerCannotCallBufferOwnerFunctions(address attacker) public {
        vm.assume(attacker != ROOT_TIMELOCK);
        vm.assume(attacker != address(0));

        vm.startPrank(attacker);

        // BufferManager uses custom error NotOwner()
        vm.expectRevert(BufferManager.NotOwner.selector);
        buffer.setPaused(true);

        vm.stopPrank();
    }

    /// @notice Random attacker cannot call GlobalConfig governor functions
    function testFuzz_attackerCannotCallGlobalConfigFunctions(address attacker) public {
        vm.assume(attacker != ROOT_TIMELOCK);
        vm.assume(attacker != address(0));

        vm.startPrank(attacker);

        vm.expectRevert(GlobalConfig.NotGovernor.selector);
        globalConfig.setGovernor(attacker);

        vm.expectRevert(GlobalConfig.NotGovernor.selector);
        globalConfig.setDefaultFees(100, 100, 100);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SECTION 8: COMPLETE SELECTOR TABLE DOCUMENTATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Log all selectors and their roles for documentation.
    /// @dev Array size must equal SelectorLib.ADMIN_MODULE_OWNER_SELECTORS (currently 34).
    ///      Indices 0-26: original set; 27-33: added post-baseline (setInitialPerfParams via
    ///      FIX-EIP7201-SLOTS-01; setIncentivesEngine + setRewardsPayoutManager via
    ///      FIX-FEECOLLECTOR-AUTOHARVEST-01; setRebalancePolicy + setRebalanceGuard +
    ///      setExecutionMemory + setStrictExecutionMemory via V10 portfolio-grade allocation engine).
    function test_logSelectorTable() public view {
        console.log("=== ADMINMODULE OWNER SELECTORS (ROLE_OWNER = 1) ===");

        bytes4[] memory ownerSels = SelectorLib.getAdminModuleOwnerSelectors();
        string[34] memory ownerNames = [
            "submitFeeParams",
            "acceptFeeParams",
            "revokeFeeParams",
            "submitPerfParams",
            "acceptPerfParams",
            "revokePerfParams",
            "submitMinDelay",
            "acceptMinDelay",
            "revokeMinDelay",
            "setParams",
            "setBufferManager",
            "setRouter",
            "setHealthRegistry",
            "setIncentives",
            "setFeeCollector",
            "setVetoer",
            "freezeParams",
            "setEcosystem",
            "enableComponentsTimelock",
            "submitBufferManager",
            "acceptBufferManager",
            "revokeBufferManager",
            "submitRouter",
            "acceptRouter",
            "revokeRouter",
            "seedDeadDeposit",
            "setInitialFees",
            "setInitialPerfParams",
            "setIncentivesEngine",
            "setRewardsPayoutManager",
            "setRebalancePolicy",
            "setRebalanceGuard",
            "setExecutionMemory",
            "setStrictExecutionMemory"
        ];

        for (uint256 i = 0; i < ownerSels.length; i++) {
            uint8 role = vault.roleOf(ownerSels[i]);
            console.log("%s: selector=%s role=%d", ownerNames[i], vm.toString(ownerSels[i]), role);
            assertEq(
                role, ROLE_OWNER, string(abi.encodePacked(ownerNames[i], " must be ROLE_OWNER"))
            );
        }

        console.log("\n=== QUEUEMODULE SELECTORS (ROLE_PUBLIC = 0) ===");

        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        // string[6]: index 5 = "compactQueue" added when QUEUE_MODULE_SELECTORS grew from 5 to 6.
        string[6] memory queueNames = [
            "requestClaim",
            "cancelClaim",
            "processQueuedRedemptions",
            "settleFeesAndProcessQueue",
            "endEpochCrystallize",
            "compactQueue"
        ];

        for (uint256 i = 0; i < queueSels.length; i++) {
            uint8 role = vault.roleOf(queueSels[i]);
            console.log("%s: selector=%s role=%d", queueNames[i], vm.toString(queueSels[i]), role);
            assertEq(
                role, ROLE_PUBLIC, string(abi.encodePacked(queueNames[i], " must be ROLE_PUBLIC"))
            );
        }
    }
}
