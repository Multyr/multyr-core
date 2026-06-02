// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ==============================================================================
// SPRINT SECURITY TEST -- Two AdminModule governance bypass vulnerabilities
//
// FINDING-02 (HIGH): setEcosystem bypasses FLAG_COMPONENTS_TIMELOCKED
// FINDING-03 (MEDIUM): submitPerfParams / submitMinDelay / submitBufferManager /
//                       submitRouter silently overwrite pending submissions
//
// ============================================================================
// FINDING-02 -- setEcosystem bypasses FLAG_COMPONENTS_TIMELOCKED
// ============================================================================
//
// enableComponentsTimelock() sets FLAG_COMPONENTS_TIMELOCKED so that direct
// calls to setBufferManager and setRouter revert:
//
//   function setBufferManager(address newBuffer) external {
//       if (core.packedFlags & CoreStorage.FLAG_COMPONENTS_TIMELOCKED != 0)
//           revert ComponentsTimelocked();    <-- blocked
//   }
//
// setEcosystem(), which sets BOTH bufferManager AND strategyRouter atomically,
// only checks _requireNotSealed() -- it never inspects FLAG_COMPONENTS_TIMELOCKED:
//
//   function setEcosystem(EcosystemConfig calldata config) external {
//       _requireNotSealed();                  <-- only seal check
//       core.bufferManager = IBufferManager(config.bufferManager);  <-- set immediately
//       core.router        = IStrategyRouter(config.strategyRouter); <-- set immediately
//   }
//
// IMPACT: After enableComponentsTimelock() the owner can silently swap both
// critical infrastructure contracts to malicious ones in a single call with
// ZERO timelock delay, bypassing the entire protection the flag was designed
// to provide.
//
// FIX: Add the same FLAG_COMPONENTS_TIMELOCKED guard to setEcosystem, or
//      gate setEcosystem so it reverts once the component timelock is enabled.
//
// ============================================================================
// FINDING-03 -- submitPerfParams / submitMinDelay silently overwrite pending
// ============================================================================
//
// submitFeeParams has a guard:
//
//   if (FeeStorage.layout().pendingFee.exists) revert PendingParamsNotResolved();
//
// submitPerfParams and submitMinDelay have NO equivalent guard:
//
//   function submitPerfParams(uint256 rateX, uint64 minInterval) external {
//       // no pendingPerf.exists check
//       f.pendingPerf.rateX      = rateX;   // silent overwrite
//       f.pendingPerf.minInterval = minInterval;
//       f.pendingPerf.eta         = eta;
//       f.pendingPerf.exists      = true;
//   }
//
// ATTACK PATTERN:
//   1. Owner submits perf rate = 10 % (acceptable; vetoer stands down).
//   2. Owner immediately calls submitPerfParams(50 %, ...) in the same block.
//      The pending slot is silently overwritten with no new ETA event that
//      distinguishes it from a fresh submission.
//   3. Vetoer monitored step 1 and decided not to revoke. She has no signal
//      that the value changed. After the ETA the 50 % rate takes effect.
//
// The same silent-overwrite applies to:
//   - submitMinDelay    (can be used to ratchet delay to extreme values)
//   - submitBufferManager
//   - submitRouter
//
// FIX: Add if (f.pendingPerf.exists) revert PendingParamsNotResolved(); and
//      equivalent guards to all four submit functions.
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
    // direct setter.  This is the EXPECTED behaviour that setEcosystem bypasses.
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
    // TEST F2-2: setEcosystem bypasses FLAG_COMPONENTS_TIMELOCKED
    //
    // After enableComponentsTimelock(), setBufferManager reverts but
    // setEcosystem succeeds and instantly swaps both infrastructure contracts.
    // -------------------------------------------------------------------------
    function test_f02_poc_setEcosystem_bypasses_component_timelock() public {
        address maliciousBM     = makeAddr("maliciousBM");
        address maliciousRouter = makeAddr("maliciousRouter");
        address guardian        = makeAddr("guardian");

        // Capture the original addresses
        IAdminModule.EcosystemConfig memory before = IAdminModule(address(core)).getEcosystem();
        address originalBM     = before.bufferManager;
        address originalRouter = before.strategyRouter;

        // Enable the component timelock -- direct setters are now blocked
        IAdminModule(address(core)).enableComponentsTimelock();

        // Confirm that direct setters revert
        vm.expectRevert(AdminModule.ComponentsTimelocked.selector);
        IAdminModule(address(core)).setBufferManager(maliciousBM);

        // BUG: setEcosystem does NOT check FLAG_COMPONENTS_TIMELOCKED and succeeds
        IAdminModule(address(core)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager:  maliciousBM,
            strategyRouter: maliciousRouter,
            healthRegistry: address(0),
            incentives:     address(0),
            guardian:       guardian,
            vetoer:         address(0)
        }));

        // Both infrastructure contracts were swapped with ZERO timelock delay
        IAdminModule.EcosystemConfig memory after_ = IAdminModule(address(core)).getEcosystem();

        assertEq(
            after_.bufferManager,
            maliciousBM,
            "BUG CONFIRMED: bufferManager replaced instantly, bypassing component timelock"
        );
        assertEq(
            after_.strategyRouter,
            maliciousRouter,
            "BUG CONFIRMED: strategyRouter replaced instantly, bypassing component timelock"
        );

        // Originals are gone
        assertTrue(after_.bufferManager  != originalBM,     "original bufferManager overwritten");
        assertTrue(after_.strategyRouter != originalRouter,  "original strategyRouter overwritten");
    }

    // -------------------------------------------------------------------------
    // TEST F2-3: setEcosystem swaps both contracts atomically without delay
    //
    // Quantifies the blast radius: a single call swaps BOTH contracts at once,
    // giving the protocol no intermediate safe state.
    // -------------------------------------------------------------------------
    function test_f02_poc_setEcosystem_swaps_both_components_atomically() public {
        address maliciousBM     = makeAddr("maliciousBM");
        address maliciousRouter = makeAddr("maliciousRouter");
        address guardian        = makeAddr("guardian");

        IAdminModule(address(core)).enableComponentsTimelock();

        uint256 tBefore = block.timestamp;

        // Single call -- no warp, no delay, no timelock operations
        IAdminModule(address(core)).setEcosystem(IAdminModule.EcosystemConfig({
            bufferManager:  maliciousBM,
            strategyRouter: maliciousRouter,
            healthRegistry: address(0),
            incentives:     address(0),
            guardian:       guardian,
            vetoer:         address(0)
        }));

        // Confirm: no time elapsed
        assertEq(block.timestamp, tBefore, "no time passed -- bypass is instant");

        IAdminModule.EcosystemConfig memory cfg = IAdminModule(address(core)).getEcosystem();
        assertEq(cfg.bufferManager,  maliciousBM,     "BM swapped in same block");
        assertEq(cfg.strategyRouter, maliciousRouter,  "Router swapped in same block");
    }

    // =========================================================================
    // FINDING-03 TESTS
    // =========================================================================

    // -------------------------------------------------------------------------
    // TEST F3-1: Control -- submitFeeParams correctly blocks overwrite
    //
    // Demonstrates that the PendingParamsNotResolved guard WORKS for fee params.
    // This is the pattern that submitPerfParams and submitMinDelay SHOULD follow.
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
    // TEST F3-2: submitPerfParams silently overwrites pending submission
    //
    // The vetoer observes a 10 % rate submission and decides not to revoke.
    // Before the ETA the owner overwrites with the maximum 50 % rate.
    // After the timelock the 50 % rate takes effect -- the vetoer was deceived.
    // -------------------------------------------------------------------------
    function test_f03_poc_submitPerfParams_silent_overwrite_fools_vetoer() public {
        // --- Submit acceptable rate (vetoer stands down) ----------------------
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_10PCT, 0);

        {
            (uint256 pendingRate,,, bool exists) =
                IAdminModule(address(core)).getPendingPerfParams();
            assertTrue(exists,                      "pending must exist after first submit");
            assertEq(pendingRate, PERF_RATE_10PCT,  "pending rate is 10% after first submit");
        }

        // --- Owner overwrites in the SAME block -- should revert but does NOT -
        // (No PendingParamsNotResolved guard on submitPerfParams)
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_50PCT, 0);

        {
            (uint256 pendingRate,,, bool exists) =
                IAdminModule(address(core)).getPendingPerfParams();
            assertTrue(exists,                       "pending must still exist");
            assertEq(
                pendingRate,
                PERF_RATE_50PCT,
                "BUG: pending slot was silently overwritten with 50 % rate"
            );
        }

        // --- Advance past the ETA and accept ----------------------------------
        vm.warp(block.timestamp + TWO_DAYS + 1);
        IAdminModule(address(core)).acceptPerfParams();

        // --- Verify the OVERWRITTEN (higher) rate took effect -----------------
        (uint256 activeRate,,,) = IAdminModule(address(core)).getPerfParams();
        assertEq(
            activeRate,
            PERF_RATE_50PCT,
            "BUG CONFIRMED: 50 % rate accepted -- vetoer window was bypassed"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-3: submitPerfParams second submission does not extend the ETA
    //
    // Because ETA = block.timestamp + paramMinDelay, overwriting in the same
    // block keeps the SAME ETA. The vetoer who saw the first submission and
    // its ETA has no extra time to react to the overwritten value.
    // -------------------------------------------------------------------------
    function test_f03_poc_submitPerfParams_overwrite_keeps_same_eta() public {
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_10PCT, 0);
        (,, uint64 etaFirst,) = IAdminModule(address(core)).getPendingPerfParams();

        // Overwrite in the same block
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_50PCT, 0);
        (,, uint64 etaSecond,) = IAdminModule(address(core)).getPendingPerfParams();

        // ETA is identical -- no additional delay for the higher rate
        assertEq(
            etaSecond,
            etaFirst,
            "BUG: overwrite does not extend ETA -- vetoer has no extra time to react"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-4: submitMinDelay silently overwrites pending delay
    //
    // Owner submits 3-day delay (acceptable), then immediately overwrites with
    // 7-day delay without triggering a revert.  After acceptance the extreme
    // delay is active, making future governance slower than vetoer expected.
    // -------------------------------------------------------------------------
    function test_f03_poc_submitMinDelay_silent_overwrite() public {
        // Both values are above the minParamDelay floor (2 days) from MockParamsProvider
        uint64 acceptableDelay = THREE_DAYS;
        uint64 extremeDelay    = SEVEN_DAYS;

        // First submission -- acceptable value
        IAdminModule(address(core)).submitMinDelay(acceptableDelay);

        {
            (uint64 pending,, bool exists) =
                IAdminModule(address(core)).getPendingMinDelay();
            assertTrue(exists,                        "pending delay must exist");
            assertEq(pending, acceptableDelay,        "pending is 3 days after first submit");
        }

        // Overwrite with extreme value -- should revert but does NOT
        IAdminModule(address(core)).submitMinDelay(extremeDelay);

        {
            (uint64 pending,, bool exists) =
                IAdminModule(address(core)).getPendingMinDelay();
            assertEq(
                pending,
                extremeDelay,
                "BUG: pending delay silently overwritten with 7 days"
            );
            assertTrue(exists, "pending still exists after overwrite");
        }

        // Accept after ETA -- extreme delay takes effect
        vm.warp(block.timestamp + TWO_DAYS + 1);
        IAdminModule(address(core)).acceptMinDelay();

        uint64 activeDelay = IAdminModule(address(core)).getMinDelay();
        assertEq(
            activeDelay,
            extremeDelay,
            "BUG CONFIRMED: 7-day delay accepted -- vetoer saw 3-day submission, gets 7-day result"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-5: submitBufferManager silently overwrites pending submission
    //
    // After enableComponentsTimelock, the owner submits a legitimate BM then
    // immediately overwrites with a malicious address.  The accepted BM is the
    // malicious one -- all within the same timelock window.
    // -------------------------------------------------------------------------
    function test_f03_poc_submitBufferManager_silent_overwrite() public {
        address legitimateBM = address(new MockBufferManagerForTests(address(core)));
        address maliciousBM  = makeAddr("maliciousBM");

        // Component timelock must be enabled before submitBufferManager is valid
        IAdminModule(address(core)).enableComponentsTimelock();

        // First submission -- legitimate BM that vetoer accepts
        IAdminModule(address(core)).submitBufferManager(legitimateBM);

        {
            (address pending,, bool exists) =
                IAdminModule(address(core)).getPendingBufferManager();
            assertEq(pending, legitimateBM, "pending BM is legitimate after first submit");
            assertTrue(exists, "pending BM exists");
        }

        // Overwrite with malicious BM -- should revert but does NOT
        IAdminModule(address(core)).submitBufferManager(maliciousBM);

        {
            (address pending,, bool exists) =
                IAdminModule(address(core)).getPendingBufferManager();
            assertEq(
                pending,
                maliciousBM,
                "BUG: pending BM silently overwritten with malicious address"
            );
            assertTrue(exists, "pending still exists after overwrite");
        }

        // Accept after ETA -- malicious BM takes effect
        vm.warp(block.timestamp + TWO_DAYS + 1);
        IAdminModule(address(core)).acceptBufferManager();

        IAdminModule.EcosystemConfig memory cfg = IAdminModule(address(core)).getEcosystem();
        assertEq(
            cfg.bufferManager,
            maliciousBM,
            "BUG CONFIRMED: malicious bufferManager accepted -- vetoer saw legitimate submission"
        );
    }

    // -------------------------------------------------------------------------
    // TEST F3-6: All three broken submits can be chained to bypass every
    //            governance guard in a single block
    //
    // The owner submits a misleading value for each parameter type, waits for
    // the vetoer's silence window, then overwrites all three in the same block.
    // All three overwrite calls succeed (no revert).
    // -------------------------------------------------------------------------
    function test_f03_poc_all_three_overwrites_succeed_in_one_block() public {
        IAdminModule(address(core)).enableComponentsTimelock();
        address legitBM = address(new MockBufferManagerForTests(address(core)));

        // Submit all three with acceptable/misleading values
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_10PCT, 0);
        IAdminModule(address(core)).submitMinDelay(THREE_DAYS);
        IAdminModule(address(core)).submitBufferManager(legitBM);

        // Overwrite all three in the same block -- none revert
        IAdminModule(address(core)).submitPerfParams(PERF_RATE_50PCT, 0);
        IAdminModule(address(core)).submitMinDelay(SEVEN_DAYS);
        IAdminModule(address(core)).submitBufferManager(makeAddr("maliciousBM"));

        // All three pending slots now hold the extreme/malicious values
        {
            (uint256 rate,,,)         = IAdminModule(address(core)).getPendingPerfParams();
            (uint64  delay,,)         = IAdminModule(address(core)).getPendingMinDelay();
            (address bm,,)            = IAdminModule(address(core)).getPendingBufferManager();

            assertEq(rate,  PERF_RATE_50PCT,            "perf rate overwritten to 50 %");
            assertEq(delay, SEVEN_DAYS,                  "delay overwritten to 7 days");
            assertEq(bm,    makeAddr("maliciousBM"),     "BM overwritten with malicious address");
        }
    }
}
