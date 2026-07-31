// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20Mock } from "../../../src/mocks/ERC20Mock.sol";
import { StrategyRouter } from "../../../src/core/modules/StrategyRouter.sol";
import { StrategyMock } from "../../helpers/StrategyMock.sol";

/// @dev Minimal core stand-in: StrategyRouter.register() only needs core.asset()
///      to resolve and match the strategy's own asset() during registration.
contract MockCoreAsset {
    address public immutable asset_;

    constructor(address asset__) {
        asset_ = asset__;
    }

    function asset() external view returns (address) {
        return asset_;
    }
}

/// @title StrategyRouter_Allowlist
/// @notice D1 (Audit Fix): register() must only accept strategy addresses that were
///         independently vetted through a propose -> wait -> execute timelock before
///         register() will accept them.
/// @dev The delay is the actual control: propose + execute cannot be collapsed into a
///      single (e.g. multisig-batched) transaction because executeStrategyAllowlist()
///      hard-requires block.timestamp >= eta. A copy-pasted wrong address therefore
///      gets a mandatory real-time review window before it can touch funds, even when
///      `owner` is a single multisig controlling both steps.
contract StrategyRouter_Allowlist is Test {
    ERC20Mock internal usdc;
    MockCoreAsset internal core;
    StrategyRouter internal router;
    StrategyMock internal strat;

    address internal owner = address(this);
    address internal attacker = address(0xBAD);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        core = new MockCoreAsset(address(usdc));
        router = new StrategyRouter(owner, address(core), address(0xCAFE));
        strat = new StrategyMock(address(usdc));
    }

    // ---------------- register() gating ----------------

    function test_register_reverts_when_never_proposed() public {
        vm.expectRevert(bytes("not-allowlisted"));
        router.register(address(strat), 0, 1e4);
    }

    function test_register_reverts_before_timelock_elapses() public {
        router.proposeStrategyAllowlist(address(strat));

        vm.expectRevert(bytes("not-allowlisted"));
        router.register(address(strat), 0, 1e4);

        // Even right up to (but not past) eta.
        vm.warp(block.timestamp + router.strategyAllowlistDelay() - 1);
        vm.expectRevert(bytes("not-allowlisted"));
        router.register(address(strat), 0, 1e4);
    }

    function test_register_succeeds_after_full_timelock_flow() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));

        router.register(address(strat), 0, 1e4);
        assertTrue(router.isStrategyEnabled(address(strat)));
    }

    // ---------------- propose ----------------

    function test_proposeStrategyAllowlist_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("not-owner"));
        router.proposeStrategyAllowlist(address(strat));
    }

    function test_proposeStrategyAllowlist_rejects_zero_address() public {
        vm.expectRevert(bytes("strat=0"));
        router.proposeStrategyAllowlist(address(0));
    }

    /// @dev Catches the exact typo scenario Shivam flagged: proposing an address with
    ///      no deployed code (e.g. an EOA from a mistyped strategy address) must fail
    ///      loudly at proposal time instead of silently queuing.
    function test_proposeStrategyAllowlist_rejects_eoa() public {
        address eoaTypo = address(0x1234);
        vm.expectRevert(bytes("not-contract"));
        router.proposeStrategyAllowlist(eoaTypo);
    }

    function test_proposeStrategyAllowlist_rejects_already_allowlisted() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));

        vm.expectRevert(bytes("already-allowlisted"));
        router.proposeStrategyAllowlist(address(strat));
    }

    function test_proposeStrategyAllowlist_returns_correct_eta() public {
        uint256 expected = block.timestamp + router.strategyAllowlistDelay();
        uint256 eta = router.proposeStrategyAllowlist(address(strat));
        assertEq(eta, expected);
        assertEq(router.strategyAllowlistEta(address(strat)), expected);
    }

    // ---------------- execute ----------------

    function test_executeStrategyAllowlist_onlyOwner() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());

        vm.prank(attacker);
        vm.expectRevert(bytes("not-owner"));
        router.executeStrategyAllowlist(address(strat));
    }

    function test_executeStrategyAllowlist_reverts_without_proposal() public {
        vm.expectRevert(bytes("no-proposal"));
        router.executeStrategyAllowlist(address(strat));
    }

    function test_executeStrategyAllowlist_reverts_before_eta() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.expectRevert(bytes("timelock-not-passed"));
        router.executeStrategyAllowlist(address(strat));
    }

    function test_executeStrategyAllowlist_reverts_after_grace_period() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(
            block.timestamp + router.strategyAllowlistDelay() + router.ALLOWLIST_GRACE_PERIOD() + 1
        );
        vm.expectRevert(bytes("proposal-expired"));
        router.executeStrategyAllowlist(address(strat));
    }

    function test_executeStrategyAllowlist_clears_pending_eta() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));

        assertEq(router.strategyAllowlistEta(address(strat)), 0);
        assertTrue(router.strategyAllowlist(address(strat)));
    }

    // ---------------- cancel ----------------

    function test_cancelStrategyAllowlistProposal_onlyOwner() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.prank(attacker);
        vm.expectRevert(bytes("not-owner"));
        router.cancelStrategyAllowlistProposal(address(strat));
    }

    function test_cancelStrategyAllowlistProposal_blocks_subsequent_execute() public {
        router.proposeStrategyAllowlist(address(strat));
        router.cancelStrategyAllowlistProposal(address(strat));

        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        vm.expectRevert(bytes("no-proposal"));
        router.executeStrategyAllowlist(address(strat));
    }

    function test_cancelStrategyAllowlistProposal_reverts_without_proposal() public {
        vm.expectRevert(bytes("no-proposal"));
        router.cancelStrategyAllowlistProposal(address(strat));
    }

    // ---------------- revoke ----------------

    function test_revokeStrategyAllowlist_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("not-owner"));
        router.revokeStrategyAllowlist(address(strat));
    }

    /// @dev Revocation is intentionally instant (no timelock) — removing trust is a
    ///      safety action and must not be gated behind the same delay as granting it.
    function test_revokeStrategyAllowlist_is_instant_and_blocks_registration() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));
        router.register(address(strat), 0, 1e4);

        router.revokeStrategyAllowlist(address(strat));
        assertFalse(router.strategyAllowlist(address(strat)));

        // A second strategy can no longer be onboarded once revoked, even though
        // the first was already registered before revocation.
        StrategyMock strat2 = new StrategyMock(address(usdc));
        vm.expectRevert(bytes("not-allowlisted"));
        router.register(address(strat2), 1, 1e4);
    }

    /// @dev The gap this closes: revoke used to only block FUTURE registrations —
    ///      a strategy already registered stayed enabled (and kept receiving
    ///      deposits/redeems) after revoke. "Removing trust is instant" wasn't
    ///      actually true for the strategies that are managing money. Revoke must
    ///      also disable an already-registered strategy, exactly like toggle(strat,
    ///      false) would.
    function test_revokeStrategyAllowlist_disablesAlreadyRegisteredStrategy() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));
        router.register(address(strat), 0, 1e4);
        assertTrue(router.isStrategyEnabled(address(strat)), "enabled after register");

        router.revokeStrategyAllowlist(address(strat));

        assertFalse(router.strategyAllowlist(address(strat)), "allowlist revoked");
        assertFalse(router.isStrategyEnabled(address(strat)), "strategy disabled by revoke, not just delisted");
    }

    /// @dev Revoking a strategy that was never registered (only proposed, or never
    ///      even proposed) must not revert — there's no StrategyInfo entry to touch.
    function test_revokeStrategyAllowlist_neverRegistered_doesNotRevert() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));
        // Never registered.

        router.revokeStrategyAllowlist(address(strat)); // must not revert

        assertFalse(router.strategyAllowlist(address(strat)));
    }

    /// @dev Revoking an already-disabled registered strategy must not emit a
    ///      redundant StrategyToggled event — idempotency on the disable side.
    function test_revokeStrategyAllowlist_alreadyDisabled_noRedundantToggleEvent() public {
        router.proposeStrategyAllowlist(address(strat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(strat));
        router.register(address(strat), 0, 1e4);
        router.toggle(address(strat), false); // already disabled independently of revoke

        vm.recordLogs();
        router.revokeStrategyAllowlist(address(strat));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != keccak256("StrategyToggled(address,bool)"),
                "no StrategyToggled emitted when strategy was already disabled"
            );
        }
        assertFalse(router.isStrategyEnabled(address(strat)));
    }

    function test_revokeStrategyAllowlist_clears_pending_proposal() public {
        router.proposeStrategyAllowlist(address(strat));
        router.revokeStrategyAllowlist(address(strat)); // revoke before ever executed

        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        vm.expectRevert(bytes("no-proposal"));
        router.executeStrategyAllowlist(address(strat));
    }

    // ---------------- delay configuration ----------------

    function test_setStrategyAllowlistDelay_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("not-owner"));
        router.setStrategyAllowlistDelay(3 days);
    }

    function test_setStrategyAllowlistDelay_rejects_out_of_range() public {
        uint256 tooLow = router.MIN_ALLOWLIST_DELAY() - 1;
        uint256 tooHigh = router.MAX_ALLOWLIST_DELAY() + 1;

        vm.expectRevert(bytes("delay-out-of-range"));
        router.setStrategyAllowlistDelay(tooLow);

        vm.expectRevert(bytes("delay-out-of-range"));
        router.setStrategyAllowlistDelay(tooHigh);
    }

    function test_setStrategyAllowlistDelay_applies_to_new_proposals() public {
        router.setStrategyAllowlistDelay(5 days);
        uint256 eta = router.proposeStrategyAllowlist(address(strat));
        assertEq(eta, block.timestamp + 5 days);
    }

    // ---------------- interaction with existing asset() check ----------------

    function test_allowlisting_does_not_bypass_asset_mismatch_check() public {
        ERC20Mock otherAsset = new ERC20Mock("DAI", "DAI", 18);
        StrategyMock wrongAssetStrat = new StrategyMock(address(otherAsset));

        router.proposeStrategyAllowlist(address(wrongAssetStrat));
        vm.warp(block.timestamp + router.strategyAllowlistDelay());
        router.executeStrategyAllowlist(address(wrongAssetStrat));

        vm.expectRevert(bytes("asset-mismatch"));
        router.register(address(wrongAssetStrat), 0, 1e4);
    }
}
