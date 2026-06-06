// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ==============================================================================
// SPRINT SECURITY TEST -- Two AdminModule governance bypass vulnerabilities
//
// FINDING-02 (HIGH): setEcosystem bypasses FLAG_COMPONENTS_TIMELOCKED
// FINDING-03 (MEDIUM): submitPerfParams / submitMinDelay / submitBufferManager /
//                       submitRouter silently overwrite pending submissions
//
// ==============================================================================
// FINDING-02 -- setEcosystem bypasses FLAG_COMPONENTS_TIMELOCKED
// ==============================================================================
//
// enableComponentsTimelock() sets FLAG_COMPONENTS_TIMELOCKED so that direct
// calls to setBufferManager and setRouter revert with ComponentsTimelocked.
//
// BUG: setEcosystem(), which sets BOTH bufferManager AND strategyRouter atomically,
// only checked _requireNotSealed() -- it never inspected FLAG_COMPONENTS_TIMELOCKED.
// After enableComponentsTimelock() the owner could silently swap both critical
// infrastructure contracts to malicious ones in a single call with ZERO delay.
//
// FIX: Added FLAG_COMPONENTS_TIMELOCKED guard to setEcosystem so it reverts
//      with ComponentsTimelocked once the component timelock is enabled.
//
// ==============================================================================
// FINDING-03 -- submitPerfParams / submitMinDelay silently overwrite pending
// ==============================================================================
//
// submitFeeParams has a guard:
//   if (FeeStorage.layout().pendingFee.exists) revert PendingParamsNotResolved();
//
// BUG: submitPerfParams, submitMinDelay, submitBufferManager, and submitRouter
// had NO equivalent guard -- a pending slot could be silently overwritten with
// a different value in the same block, deceiving the vetoer.
//
// FIX: Added if (f.pendingXxx.exists) revert PendingParamsNotResolved(); to all
//      four submit functions, matching the pattern already used by submitFeeParams.
// ==============================================================================

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness }          from "../helpers/CoreHarness.sol";
import { MockUSDC }             from "../helpers/MockUSDC.sol";
import { MockParamsProvider }   from "../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../helpers/MockBufferManagerForTests.sol";

import { AdminModule }          from "../../src/core/modules/AdminModule.sol";
import { IAdminModule }         from "../../src/interfaces/IAdminModule.sol";
import { CoreStorage }          from "../../src/core/storage/CoreStorage.sol";

// =============================================================================
// Extended harness: adds the selectors CoreHarness does not wire by default
// =============================================================================
contract GovernanceTestHarness is CoreHarness {
    constructor(
        IERC20Metadata assetUSDC,
        string memory name_,
        string memory symbol_,
        address owner_,
        address treasury_,
        address params_
    ) CoreHarness(assetUSDC, name_, symbol_, owner_, treasury_, params_) {
        // Component timelock control
        _setModuleUnsafe(AdminModule.enableComponentsTimelock.selector,  address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.isComponentsTimelocked.selector,    address(adminModule), ROLE_PUBLIC);
        _setModuleUnsafe(AdminModule.submitBufferManager.selector,       address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.acceptBufferManager.selector,       address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.revokeBufferManager.selector,       address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.submitRouter.selector,              address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.acceptRouter.selector,              address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.revokeRouter.selector,              address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.getPendingBufferManager.selector,   address(adminModule), ROLE_PUBLIC);
        _setModuleUnsafe(AdminModule.getPendingRouter.selector,          address(adminModule), ROLE_PUBLIC);

        // Atomic ecosystem setter (Finding-02 target)
        _setModuleUnsafe(AdminModule.setEcosystem.selector,  address(adminModule), ROLE_OWNER);
        _setModuleUnsafe(AdminModule.getEcosystem.selector,  address(adminModule), ROLE_PUBLIC);
    }
}

// =============================================================================
// POC test contract
// =============================================================================
contract AdminModule_GovernanceBypass_POC is Test {
    // -------------------------------------------------------------------------
    // constants
    // -------------------------------------------------------------------------
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Perf rates (WAD-scaled): 10 % and max 50 %
    uint256 constant PERF_RATE_10PCT = 1e17;
    uint256 constant PERF_RATE_50PCT = 5e17; // maxPerfRate in MockParamsProvider

    // Min delay in MockParamsProvider.minParamDelay() == 2 days
    uint64 constant TWO_DAYS   = 2 days;
    uint64 constant THREE_DAYS = 3 days;
    uint64 constant SEVEN_DAYS = 7 days;

    // -------------------------------------------------------------------------
    // state
    // -------------------------------------------------------------------------
    address internal owner;   // test contract == owner
    address internal vetoer;

    GovernanceTestHarness  internal core;
    MockUSDC               internal mock;
    MockParamsProvider     internal params;

    // -------------------------------------------------------------------------
    // setup
    // -------------------------------------------------------------------------
    function setUp() public {
        owner  = address(this);
        vetoer = makeAddr("vetoer");

        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockParamsProvider();
        core = new GovernanceTestHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            owner,
            owner,   // feeCollector
            address(params)
        );

        // Give the vault a vetoer so revoke paths are available
        IAdminModule(address(core)).setVetoer(vetoer);

        // Set a realistic 2-day paramMinDelay so ETAs are non-trivial
        core.setParamMinDelayUnsafe(TWO_DAYS);
    }

    // =========================================================================
    // FINDING-02 TESTS
    // =========================================================================

    // -------------------------------------------------------------------------
    // TEST F2-1: Sanity -- direct setBufferManager reverts after timelock enabled
    //
    // Confirms the component timelock is active and correctly blocks the
    // direct setter.  This is the baseline behaviour that setEcosystem also
    // must respect after the fix.
    // -------------------------------------------------------------------------
    function test_f02_control_setBufferManager_reverts_after_timelock() public {
        address maliciousBM = makeAddr("maliciousBM");

        // Enable the component timelock
        IAdminModule(address(core)).enableComponentsTimelock();
        assertTrue(
            IAdminModule(address(core)).isComponentsTimelocked(),
            "component timelock must be enabled"
        );

        // Direct setter MUST revert now
        vm.expectRevert(AdminModule.ComponentsTimelocked.selector);
        IAdminModule(address(core)).setBufferManager(maliciousBM);

        vm.expectRevert(AdminModule.ComponentsTimelocked.selector);
        IAdminModule(address(core)).setRouter(maliciousBM);
    }

    // -------------------------------------------------------------------------
    // TEST F2-2: FIX -- setEcosystem now reverts after FLAG_COMPONENTS_TIMELOCKED
    //
    // After enableComponentsTimelock(), setEcosystem must revert with the same
    // ComponentsTimelocked error as the individual setters.  The vault state
    // must remain unchanged.
    // -------------------------------------------------------------------------
    function test_f02_fix_setEcosystem_reverts_after_component_timelock() public {
        address maliciousBM     = makeAddr("maliciousBM");
        address maliciousRouter = makeAddr("maliciousRouter");
        address guardian        = makeAddr("guardian");

        // Capture the original addresses
        IAdminModule.EcosystemConfig memory before = IAdminModule(address(core)).getEcosystem();
        address originalBM     = before.bufferManager;
        address originalRouter = before.strategyRouter;

        // Enable the component timelock
        IAdminModule(address(core)).enableComponentsTimelock();

        // FIX: setEcosystem now reverts with ComponentsTimelocked
        vm.expectRevert(AdminModule.ComponentsTimelocked.selector);
        IAdminModule(address(core)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager:  maliciousBM,
            strategyRouter: maliciousRouter,
            healthRegistry: address(0),
            incentives:     address(0),
            guardian:       guardian,
            vetoer:         address(0)
        }));

        // Vault state is unchanged -- no bypass possible
        IAdminModule.EcosystemConfig memory after_ = IAdminModule(address(core)).getEcosystem();
        assertEq(
            after_.bufferManager,
            originalBM,
            "FIX CONFIRMED: bufferManager unchanged -- setEcosystem correctly reverted"
        );
        assertEq(
            after_.strategyRouter,
            originalRouter,
            "FIX CONFIRMED: strategyRouter unchanged -- setEcosystem correctly reverted"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F2-3: FIX -- setEcosystem cannot swap components atomically after timelock
    //
    // Confirms that no single call can bypass the timelock in a single block.
    // The only valid path post-timelock is submitBufferManager/submitRouter
    // with a full ETA delay.
    // -------------------------------------------------------------------------
    function test_f02_fix_setEcosystem_cannot_bypass_timelock_atomically() public {
        address guardian = makeAddr("guardian");

        IAdminModule(address(core)).enableComponentsTimelock();
        IAdminModule.EcosystemConfig memory before = IAdminModule(address(core)).getEcosystem();

        uint256 tBefore = block.timestamp;

        // FIX: reverts immediately -- no time-warp trick can help
        vm.expectRevert(AdminModule.ComponentsTimelocked.selector);
        IAdminModule(address(core)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager:  makeAddr("maliciousBM"),
            strategyRouter: makeAddr("maliciousRouter"),
            healthRegistry: address(0),
            incentives:     address(0),
            guardian:       guardian,
            vetoer:         address(0)
        }));

        // No time elapsed, vault state intact
        assertEq(block.timestamp, tBefore, "no time passed");
        IAdminModule.EcosystemConfig memory cfg = IAdminModule(address(core)).getEcosystem();
        assertEq(cfg.bufferManager,  before.bufferManager,  "FIX: BM not swapped");
        assertEq(cfg.strategyRouter, before.strategyRouter, "FIX: Router not swapped");
    }

    // =========================================================================
    // FINDING-03 TESTS
    // =========================================================================

    // -------------------------------------------------------------------------
    // TEST F3-1: Control -- submitFeeParams correctly blocks overwrite
    //
    // Demonstrates that the PendingParamsNotResolved guard works for fee params.
    // This is the pattern all submit functions now follow.
    // -------------------------------------------------------------------------
    function test_f03_control_submitFeeParams_reverts_on_overwrite() public {
        address treasury = makeAddr("treasury");

        // First submission succeeds
        IAdminModule(address(core)).submitFeeParams(100, 100, 0, 0, treasury);

        // Second submission must revert -- pending not resolved
        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitFeeParams(200, 200, 0, 0, treasury);
    }

    // -------------------------------------------------------------------------
    // TEST F3-2: FIX -- submitPerfParams blocks overwrite, protecting the vetoer
    //
    // The vetoer observes a 10 % rate submission and can trust that value.
    // Any attempt to overwrite it with a higher rate now reverts.
    // After the ETA the original 10 % rate takes effect -- not a covert 50 %.
    // -------------------------------------------------------------------------
    function test_f03_fix_submitPerfParams_blocks_overwrite_protecting_vetoer() public {
        // Submit acceptable rate
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_10PCT, 0);

        {
            (uint256 pendingRate,,, bool exists) =
                IAdminModule(address(core)).getPendingPerfParams();
            assertTrue(exists,                     "pending must exist after first submit");
            assertEq(pendingRate, PERF_RATE_10PCT, "pending rate is 10 % after first submit");
        }

        // FIX: second submit reverts -- vetoer's window is trustworthy
        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_50PCT, 0);

        // Pending slot still holds the original 10 % rate
        {
            (uint256 pendingRate,,, bool exists) =
                IAdminModule(address(core)).getPendingPerfParams();
            assertTrue(exists,                     "pending must still exist");
            assertEq(
                pendingRate,
                PERF_RATE_10PCT,
                "FIX: pending slot unchanged -- vetoer can trust the submitted value"
            );
        }

        // Advance past the ETA and accept -- original 10 % takes effect
        vm.warp(block.timestamp + TWO_DAYS + 1);
        IAdminModule(address(core)).acceptPerfParams();

        (uint256 activeRate,,,) = IAdminModule(address(core)).getPerfParams();
        assertEq(
            activeRate,
            PERF_RATE_10PCT,
            "FIX CONFIRMED: original 10 % rate accepted, covert 50 % overwrite was blocked"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-3: FIX -- submitPerfParams revert preserves the original ETA
    //
    // Because the overwrite reverts, the pending slot keeps both the original
    // value AND the original ETA.  The vetoer has a clean, unambiguous window.
    // -------------------------------------------------------------------------
    function test_f03_fix_submitPerfParams_revert_preserves_original_eta() public {
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_10PCT, 0);
        (,, uint64 etaFirst,) = IAdminModule(address(core)).getPendingPerfParams();

        // Overwrite attempt reverts -- ETA is not touched
        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_50PCT, 0);

        (,, uint64 etaAfterRevert,) = IAdminModule(address(core)).getPendingPerfParams();

        // ETA is identical to the first submission -- unchanged because revert
        assertEq(
            etaAfterRevert,
            etaFirst,
            "FIX: ETA unchanged after blocked overwrite -- vetoer's window is fully intact"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-4: FIX -- submitMinDelay blocks overwrite
    //
    // Owner submits a 3-day delay.  Any attempt to overwrite with a 7-day delay
    // reverts.  After acceptance the original 3-day delay is active.
    // -------------------------------------------------------------------------
    function test_f03_fix_submitMinDelay_blocks_overwrite() public {
        uint64 acceptableDelay = THREE_DAYS;
        uint64 extremeDelay    = SEVEN_DAYS;

        // First submission succeeds
        IAdminModule(address(core)).submitMinDelay(acceptableDelay);

        {
            (uint64 pending,, bool exists) =
                IAdminModule(address(core)).getPendingMinDelay();
            assertTrue(exists,                  "pending delay must exist");
            assertEq(pending, acceptableDelay,  "pending is 3 days after first submit");
        }

        // FIX: overwrite reverts
        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitMinDelay(extremeDelay);

        // Pending still holds the original acceptable value
        {
            (uint64 pending,, bool exists) =
                IAdminModule(address(core)).getPendingMinDelay();
            assertEq(
                pending,
                acceptableDelay,
                "FIX: pending delay unchanged after blocked overwrite"
            );
            assertTrue(exists, "pending still exists");
        }

        // Accept after ETA -- original 3-day delay takes effect
        vm.warp(block.timestamp + TWO_DAYS + 1);
        IAdminModule(address(core)).acceptMinDelay();

        uint64 activeDelay = IAdminModule(address(core)).getMinDelay();
        assertEq(
            activeDelay,
            acceptableDelay,
            "FIX CONFIRMED: 3-day delay accepted, extreme 7-day overwrite was blocked"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-5: FIX -- submitBufferManager blocks overwrite
    //
    // After enableComponentsTimelock, the owner submits a legitimate BM.
    // Any attempt to overwrite with a malicious address reverts.
    // The accepted BM is the legitimate one.
    // -------------------------------------------------------------------------
    function test_f03_fix_submitBufferManager_blocks_overwrite() public {
        address legitimateBM = address(new MockBufferManagerForTests(address(core)));
        address maliciousBM  = makeAddr("maliciousBM");

        IAdminModule(address(core)).enableComponentsTimelock();

        // First submission -- legitimate BM
        IAdminModule(address(core)).submitBufferManager(legitimateBM);

        {
            (address pending,, bool exists) =
                IAdminModule(address(core)).getPendingBufferManager();
            assertEq(pending, legitimateBM, "pending BM is legitimate after first submit");
            assertTrue(exists, "pending BM exists");
        }

        // FIX: overwrite with malicious BM reverts
        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitBufferManager(maliciousBM);

        // Pending still holds the legitimate address
        {
            (address pending,, bool exists) =
                IAdminModule(address(core)).getPendingBufferManager();
            assertEq(
                pending,
                legitimateBM,
                "FIX: pending BM unchanged -- malicious overwrite was blocked"
            );
            assertTrue(exists, "pending still exists after blocked overwrite");
        }

        // Accept after ETA -- legitimate BM takes effect
        vm.warp(block.timestamp + TWO_DAYS + 1);
        IAdminModule(address(core)).acceptBufferManager();

        IAdminModule.EcosystemConfig memory cfg = IAdminModule(address(core)).getEcosystem();
        assertEq(
            cfg.bufferManager,
            legitimateBM,
            "FIX CONFIRMED: legitimate bufferManager accepted, malicious overwrite was blocked"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-6: FIX -- all three overwrite attempts revert in the same block
    //
    // Confirms that the PendingParamsNotResolved guard on all three submit
    // functions holds simultaneously.  The pending slots preserve the original
    // values submitted by the owner in step 1.
    // -------------------------------------------------------------------------
    function test_f03_fix_all_three_overwrite_attempts_revert() public {
        IAdminModule(address(core)).enableComponentsTimelock();
        address legitBM = address(new MockBufferManagerForTests(address(core)));

        // Submit original acceptable values
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_10PCT, 0);
        IAdminModule(address(core)).submitMinDelay(THREE_DAYS);
        IAdminModule(address(core)).submitBufferManager(legitBM);

        // FIX: all three overwrite attempts revert
        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_50PCT, 0);

        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitMinDelay(SEVEN_DAYS);

        vm.expectRevert(AdminModule.PendingParamsNotResolved.selector);
        IAdminModule(address(core)).submitBufferManager(makeAddr("maliciousBM"));

        // All three pending slots still hold the original values
        {
            (uint256 rate,,,)  = IAdminModule(address(core)).getPendingPerfParams();
            (uint64  delay,,)  = IAdminModule(address(core)).getPendingMinDelay();
            (address bm,,)     = IAdminModule(address(core)).getPendingBufferManager();

            assertEq(rate,  PERF_RATE_10PCT, "FIX: perf rate unchanged");
            assertEq(delay, THREE_DAYS,       "FIX: delay unchanged");
            assertEq(bm,    legitBM,          "FIX: BM unchanged");
        }
    }
}
