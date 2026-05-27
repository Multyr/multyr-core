// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ──────────────────────────────────────────────────────────────────────────────
// SPRINT SECURITY TEST — forceWithdrawAll partial-payout / share-burn imbalance
//
// VULNERABILITY SUMMARY
// ─────────────────────
// `ERC4626Module.forceWithdrawAll` (ERC4626Module.sol:257) burns ALL of the
// caller's net shares unconditionally, then pays only what best-effort
// liquidity extraction managed to gather:
//
//   targetAssets = _convertToAssets(netShares)        (line 281)
//   _forcePullAllLiquidity(targetAssets, core)         (line 311)  ← best-effort
//   _processorBurn(msg.sender, netShares)              (line 314)  ← ALL shares burned
//   hot = balanceOf(address(this))
//   assetsReceived = hot >= targetAssets ? targetAssets : hot     (line 319)
//   safeTransfer(receiver, assetsReceived)             (line 322)
//
// The force-redeem path in StrategyRouter explicitly skips reverting strategies
// and has NO loss cap (StrategyRouter.sol:1078, 1085-1159):
//
//   try IStrategy(addrs[i]).withdraw(...) { ... }
//   catch { emit ForceRedeemAdapterSkipped(...); }  ← silent skip, no revert
//
// RESULT:
//   If any strategy is frozen/illiquid or returns less than requested,
//   `_forcePullAllLiquidity` returns a sub-target amount.
//   The burn still consumes ALL net shares; the user is paid
//   `min(actuallyPulled, targetAssets)` — potentially a tiny fraction of
//   their fair share value — with NO protection, NO `minAssetsOut` parameter,
//   and NO revert-on-shortfall.
//
// IMPACT:
//   A user with 1 000 000 USDC worth of shares in a vault where the bulk of
//   liquidity lives in a frozen strategy loses up to ~90 % of their value
//   while having all shares burned in the same transaction.
//
// FIX OPTIONS (either):
//   A. Add a `minAssetsOut` parameter and `revert` if payout < minAssetsOut.
//   B. Keep forceWithdrawAll as the "emergency partial" path but create a
//      separate `forceWithdrawAllOrRevert(minAssetsOut)` that reverts on
//      shortfall, clearly documenting the trade-off.
// ──────────────────────────────────────────────────────────────────────────────

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CoreHarness } from "../helpers/CoreHarness.sol";
import { MockUSDC } from "../helpers/MockUSDC.sol";
import { MockParamsProvider } from "../helpers/MockParamsProvider.sol";
import { ERC4626Module } from "../../src/core/modules/ERC4626Module.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mock strategy: reports full balance but REVERTS on any withdraw attempt.
// Models a frozen / bricked underlying (e.g. protocol paused, bridge stuck).
// ─────────────────────────────────────────────────────────────────────────────
contract MockFrozenStrategy {
    address private immutable _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) { return _asset; }
    function name() external pure returns (string memory) { return "FrozenStrategy"; }

    /// Reports the full USDC balance — router sizes the pull attempt from this.
    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    function deposit(uint256 amount) external returns (uint256) { return amount; }

    /// Always reverts — forceRedeemForWithdraw catches this and skips the strategy.
    function withdraw(uint256, address) external pure returns (uint256) {
        revert("strategy: frozen");
    }

    function withdrawAll(address) external pure returns (uint256) {
        revert("strategy: frozen");
    }

    function harvest() external pure returns (int256, uint256) { return (0, 0); }
    function setActive(bool) external {}
    function isActive() external pure returns (bool) { return true; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock strategy: reports full balance but transfers only a FRACTION on withdraw.
// Models a partially illiquid position (e.g. redemption queues, partial unlock).
// ─────────────────────────────────────────────────────────────────────────────
contract MockPartialStrategy {
    address private immutable _asset;
    uint256 private immutable _returnPctBps; // e.g. 1000 = 10 %

    constructor(address asset_, uint256 returnPctBps_) {
        _asset      = asset_;
        _returnPctBps = returnPctBps_;
    }

    function asset() external view returns (address) { return _asset; }
    function name() external pure returns (string memory) { return "PartialStrategy"; }

    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    function deposit(uint256 amount) external returns (uint256) { return amount; }

    /// Returns only `_returnPctBps / 10000` of the requested amount.
    function withdraw(uint256 amount, address to) external returns (uint256) {
        uint256 actual = amount * _returnPctBps / 10_000;
        if (actual > 0) {
            IERC20(_asset).transfer(to, actual);
        }
        return actual;
    }

    function withdrawAll(address to) external returns (uint256) {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        if (bal > 0) IERC20(_asset).transfer(to, bal);
        return bal;
    }

    function harvest() external pure returns (int256, uint256) { return (0, 0); }
    function setActive(bool) external {}
    function isActive() external pure returns (bool) { return true; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Healthy strategy: behaves correctly, returns exactly what is asked.
// Used for the control test.
// ─────────────────────────────────────────────────────────────────────────────
contract MockHealthyStrategy {
    address private immutable _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) { return _asset; }
    function name() external pure returns (string memory) { return "HealthyStrategy"; }

    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    function deposit(uint256 amount) external returns (uint256) { return amount; }

    function withdraw(uint256 amount, address to) external returns (uint256) {
        IERC20(_asset).transfer(to, amount);
        return amount;
    }

    function withdrawAll(address to) external returns (uint256) {
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        if (bal > 0) IERC20(_asset).transfer(to, bal);
        return bal;
    }

    function harvest() external pure returns (int256, uint256) { return (0, 0); }
    function setActive(bool) external {}
    function isActive() external pure returns (bool) { return true; }
}

// ─────────────────────────────────────────────────────────────────────────────
contract ForceWithdrawAll_SlippagePOC is Test {
    // ── canonical addresses ───────────────────────────────────────────────────
    address constant USDC_UNDERLYING = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // ── vault split: 10 % hot, 90 % in strategy ───────────────────────────────
    uint256 constant VAULT_TOTAL    = 1_000_000e6;
    uint256 constant HOT_BALANCE    = 100_000e6;   // 10 % — liquid in vault
    uint256 constant STRAT_BALANCE  = 900_000e6;   // 90 % — deployed to strategy

    // ── infra ─────────────────────────────────────────────────────────────────
    CoreHarness        internal core;
    MockUSDC           internal mock;
    MockParamsProvider internal params;

    address internal user;

    // ─────────────────────────────────────────────────────────────────────────
    // COMMON SETUP HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    function _baseSetUp() internal {
        user = makeAddr("user");

        mock = new MockUSDC();
        vm.etch(USDC_UNDERLYING, address(mock).code);

        params = new MockParamsProvider();
        core   = new CoreHarness(
            IERC20Metadata(USDC_UNDERLYING),
            "USDC Agg",
            "agUSDC",
            address(this), // owner
            address(this), // feeCollector / treasury
            address(params)
        );
    }

    /// @dev Deposit VAULT_TOTAL on behalf of `user`, then simulate strategy
    ///      allocation by transferring STRAT_BALANCE from vault to `stratAddr`.
    ///      After this call:
    ///        vault hot  = HOT_BALANCE    (100 k USDC)
    ///        strategy   = STRAT_BALANCE  (900 k USDC)
    ///        user shares = VAULT_TOTAL   (1 M, no deposit fee)
    ///        PPS        = 1.0
    function _depositAndAllocate(address stratAddr) internal {
        // Give user USDC and let them deposit
        MockUSDC(USDC_UNDERLYING).mint(user, VAULT_TOTAL);
        vm.prank(user);
        IERC20(USDC_UNDERLYING).approve(address(core), type(uint256).max);
        vm.prank(user);
        ERC4626Module(address(core)).deposit(VAULT_TOTAL, user);

        // Sanity: user holds all shares, vault holds all USDC
        assertEq(core.balanceOf(user), VAULT_TOTAL,    "user share balance wrong after deposit");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(address(core)), VAULT_TOTAL, "vault hot wrong after deposit");

        // Simulate vault deploying STRAT_BALANCE to the strategy
        vm.prank(address(core));
        IERC20(USDC_UNDERLYING).transfer(stratAddr, STRAT_BALANCE);

        // Verify split
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(address(core)), HOT_BALANCE,   "vault hot after alloc");
        assertEq(IERC20(USDC_UNDERLYING).balanceOf(stratAddr),     STRAT_BALANCE, "strategy after alloc");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1 — FROZEN STRATEGY: user loses 90 % of value, all shares burned
    //
    // Scenario: 90 % of vault assets are in a strategy that always reverts
    // on withdraw (frozen underlying, protocol pause, bridge down, etc.).
    //
    // Expected behaviour without the fix:
    //   forceRedeemForWithdraw catches the revert, skips the strategy.
    //   _forcePullAllLiquidity pulls nothing from strategies.
    //   Burns ALL 1 000 000 shares.
    //   Pays only the 100 000 USDC hot balance.
    //   User suffers a 90 % loss of fair value with no recourse.
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_frozen_strategy_user_loses_90_percent() public {
        _baseSetUp();

        MockFrozenStrategy frozen = new MockFrozenStrategy(USDC_UNDERLYING);

        // Register frozen strategy so router includes it in forceRedeemForWithdraw
        core.addStrategyUnsafe(address(frozen));

        _depositAndAllocate(address(frozen));

        uint256 userSharesBefore = core.balanceOf(user);
        uint256 userUSDCBefore   = IERC20(USDC_UNDERLYING).balanceOf(user);
        uint256 fairValue        = VAULT_TOTAL;     // 1 000 000 USDC at PPS = 1

        vm.prank(user);
        uint256 received = ERC4626Module(address(core)).forceWithdrawAll(user);

        uint256 userSharesAfter = core.balanceOf(user);
        uint256 userUSDCAfter   = IERC20(USDC_UNDERLYING).balanceOf(user);

        // ── All shares burned ────────────────────────────────────────────────
        assertEq(userSharesAfter, 0, "CRITICAL: all user shares must be burned");

        // ── Only hot balance paid out (10 % of fair value) ───────────────────
        assertEq(
            received,
            HOT_BALANCE,
            "CRITICAL: user received only the hot balance, not fair value"
        );
        assertEq(
            userUSDCAfter - userUSDCBefore,
            HOT_BALANCE,
            "CRITICAL: user wallet only gained the hot balance"
        );

        // ── Quantify the loss ────────────────────────────────────────────────
        uint256 lost = fairValue - received;
        assertEq(lost, STRAT_BALANCE, "user lost exactly the strategy-held amount");
        // 900 000 USDC lost while 1 000 000 worth of shares were burned.
        // Loss percentage: 90 %.
        assertGt(lost * 10_000 / fairValue, 8900, "loss should exceed 89% of fair value");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2 — PARTIAL STRATEGY (10 % return): user loses ~81 %, all shares burned
    //
    // Scenario: The strategy is partially illiquid — it only returns 10 % of
    // any requested withdrawal (e.g. redemption queue, partial unlock schedule).
    //
    //   forceRedeemForWithdraw requests 900 k → strategy returns 90 k
    //   hot after pull = 100 k + 90 k = 190 000 USDC
    //   Burns ALL 1 000 000 shares
    //   Pays 190 000 USDC (19 % of fair value)
    //   User loses 81 % of fair value with no minimum guarantee.
    // ═════════════════════════════════════════════════════════════════════════
    function test_poc_partial_strategy_user_loses_majority() public {
        _baseSetUp();

        // 10 % return rate
        MockPartialStrategy partialStrat = new MockPartialStrategy(USDC_UNDERLYING, 1000);

        core.addStrategyUnsafe(address(partialStrat));
        _depositAndAllocate(address(partialStrat));

        uint256 userUSDCBefore = IERC20(USDC_UNDERLYING).balanceOf(user);
        uint256 fairValue      = VAULT_TOTAL; // 1 000 000 USDC at PPS = 1

        // Strategy returns 10 % of 900 000 = 90 000 USDC
        uint256 stratPull    = STRAT_BALANCE * 1000 / 10_000;  // 90 000 USDC
        uint256 expectedPaid = HOT_BALANCE + stratPull;         // 190 000 USDC

        vm.prank(user);
        uint256 received = ERC4626Module(address(core)).forceWithdrawAll(user);

        uint256 userUSDCAfter  = IERC20(USDC_UNDERLYING).balanceOf(user);
        uint256 userSharesAfter = core.balanceOf(user);

        // ── All shares burned ────────────────────────────────────────────────
        assertEq(userSharesAfter, 0, "CRITICAL: all user shares must be burned");

        // ── Only partial payout ───────────────────────────────────────────────
        assertEq(
            received,
            expectedPaid,
            "CRITICAL: user received only hot + 10% of strategy balance"
        );
        assertEq(userUSDCAfter - userUSDCBefore, expectedPaid, "wallet gained partial only");

        // ── Quantify the loss ────────────────────────────────────────────────
        uint256 lost = fairValue - received;
        // Should be 810 000 USDC lost (81 % of fair value)
        assertGt(lost * 10_000 / fairValue, 8000, "loss should exceed 80% of fair value");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3 — CONTROL: healthy strategy pays full fair value
    //
    // Demonstrates that the issue is SPECIFIC to strategies that return less
    // than requested, not a general design flaw in the happy path.
    //
    // When the strategy is healthy and returns the full amount:
    //   forceRedeemForWithdraw(900 k) → strategy.withdraw(900 k, vault) → 900 k
    //   hot after pull = 100 k + 900 k = 1 000 000 USDC ≥ targetAssets
    //   Burns ALL shares (expected)
    //   Pays full 1 000 000 USDC (= fair value)
    //   No loss.
    // ═════════════════════════════════════════════════════════════════════════
    function test_control_healthy_strategy_user_gets_fair_value() public {
        _baseSetUp();

        MockHealthyStrategy healthy = new MockHealthyStrategy(USDC_UNDERLYING);

        core.addStrategyUnsafe(address(healthy));
        _depositAndAllocate(address(healthy));

        uint256 userUSDCBefore  = IERC20(USDC_UNDERLYING).balanceOf(user);
        uint256 fairValue       = VAULT_TOTAL;

        vm.prank(user);
        uint256 received = ERC4626Module(address(core)).forceWithdrawAll(user);

        uint256 userSharesAfter = core.balanceOf(user);
        uint256 userUSDCAfter   = IERC20(USDC_UNDERLYING).balanceOf(user);

        // All shares burned (expected behaviour for forceWithdrawAll)
        assertEq(userSharesAfter, 0, "shares should be burned");

        // Full fair value paid
        assertEq(received,                         fairValue, "healthy: should receive full fair value");
        assertEq(userUSDCAfter - userUSDCBefore,   fairValue, "healthy: wallet should gain full fair value");
    }
}
