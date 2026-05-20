// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CoreVault } from "src/core/CoreVault.sol";
import { QueueModule } from "src/core/modules/QueueModule.sol";
import { AdminModule } from "src/core/modules/AdminModule.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";
import { SelectorLib } from "src/core/libraries/SelectorLib.sol";
import { ExitEngineLib } from "src/core/libraries/ExitEngineLib.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";
import { MockParamsProvider } from "test/helpers/MockParamsProvider.sol";
import { ModuleSetter } from "test/helpers/ModuleSetter.sol";
import { CoreHarness } from "test/helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "test/helpers/MockBufferManagerForTests.sol";

interface IQueueModule {
    function requestClaim(bool immediate, uint256 shares) external;
}

/// @title CoreVault ERC4626 Golden Tests
/// @notice Tests ERC4626 shares/assets/fee calculations with exact expected values
/// @dev These tests serve as "golden tests" - they verify exact numeric outputs
contract CoreVault_ERC4626_Test is Test {
    CoreVault public vault;
    ERC20Mock public usdc;
    MockParamsProvider public params;
    QueueModule public queueModule;
    AdminModule public adminModule;

    address public owner = address(this);
    address public feeCollector = address(0xFEE5);
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);

    uint256 constant INITIAL_BALANCE = 1_000_000e6;

    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock("USDC", "USDC", 6);
        usdc._mint(user1, INITIAL_BALANCE);
        usdc._mint(user2, INITIAL_BALANCE);
        usdc._mint(owner, INITIAL_BALANCE);

        // Deploy params provider
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        // Deploy vault (via CoreHarness for setBufferManagerUnsafe)
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault Shares",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;

        // Deploy and configure modules
        queueModule = new QueueModule();
        adminModule = new AdminModule();

        bytes4[] memory queueSels = SelectorLib.getQueueModuleSelectors();
        ModuleSetter.setModulesSame(
            address(vault), queueSels, address(queueModule), SelectorLib.ROLE_PUBLIC
        );

        bytes4[] memory adminOwnerSels = SelectorLib.getAdminModuleOwnerSelectors();
        ModuleSetter.setModulesSame(
            address(vault), adminOwnerSels, address(adminModule), SelectorLib.ROLE_OWNER
        );

        bytes4[] memory adminViewSels = SelectorLib.getAdminModuleViewSelectors();
        ModuleSetter.setModulesSame(
            address(vault), adminViewSels, address(adminModule), SelectorLib.ROLE_PUBLIC
        );

        // Note: Internal module selectors are no longer routed - they use msg.sender == address(this)
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIAL STATE - 1:1 RATIO
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice First deposit should receive shares 1:1 (minus any fee)
    function test_golden_firstDeposit_1to1_noFee() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);

        uint256 expectedShares = depositAmount; // 1:1 ratio initially, no fee
        uint256 actualShares = vault.deposit(depositAmount, user1);
        vm.stopPrank();

        assertEq(actualShares, expectedShares, "Golden: first deposit 1:1");
        assertEq(vault.balanceOf(user1), expectedShares, "Golden: user balance");
        assertEq(vault.totalAssets(), depositAmount, "Golden: total assets");
        assertEq(vault.totalSupply(), expectedShares, "Golden: total supply");
    }

    /// @notice previewDeposit should return exact shares for given assets
    function test_golden_previewDeposit_empty() public view {
        uint256 assets = 100e6;
        uint256 expectedShares = 100e6; // Empty vault = 1:1

        assertEq(vault.previewDeposit(assets), expectedShares, "Golden: previewDeposit empty vault");
    }

    /// @notice previewMint should return exact assets for given shares
    function test_golden_previewMint_empty() public view {
        uint256 shares = 100e6;
        uint256 expectedAssets = 100e6; // Empty vault = 1:1

        assertEq(vault.previewMint(shares), expectedAssets, "Golden: previewMint empty vault");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MULTI-USER DEPOSITS - SAME PPS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Second depositor gets same PPS as first
    function test_golden_secondDeposit_samePPS() public {
        // User1 deposits first
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        // User2 deposits same amount - should get same shares
        vm.startPrank(user2);
        usdc.approve(address(vault), 1000e6);
        uint256 shares2 = vault.deposit(1000e6, user2);
        vm.stopPrank();

        assertEq(shares2, 1000e6, "Golden: second deposit same shares");
        assertEq(vault.balanceOf(user1), vault.balanceOf(user2), "Golden: equal balances");
    }

    /// @notice Multiple deposits maintain correct PPS
    function test_golden_multipleDeposits_correctTotals() public {
        // User1 deposits 500
        vm.startPrank(user1);
        usdc.approve(address(vault), 500e6);
        vault.deposit(500e6, user1);
        vm.stopPrank();

        // User2 deposits 300
        vm.startPrank(user2);
        usdc.approve(address(vault), 300e6);
        vault.deposit(300e6, user2);
        vm.stopPrank();

        // Owner deposits 200
        usdc.approve(address(vault), 200e6);
        vault.deposit(200e6, owner);

        assertEq(vault.totalAssets(), 1000e6, "Golden: total assets = 1000");
        assertEq(vault.totalSupply(), 1000e6, "Golden: total supply = 1000");
        assertEq(vault.balanceOf(user1), 500e6, "Golden: user1 shares");
        assertEq(vault.balanceOf(user2), 300e6, "Golden: user2 shares");
        assertEq(vault.balanceOf(owner), 200e6, "Golden: owner shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // WITHDRAWALS — QUEUED PROTOCOL (ExitEngineLib Architecture)
    // withdraw()/redeem() ALWAYS revert AsyncWithdrawalRequired.
    // Users must use requestClaim(true) for instant or requestClaim(false) for queued.
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice withdraw() always reverts with AsyncWithdrawalRequired
    function test_golden_withdraw_reverts_async() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);

        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(400e6, user1, user1);
        vm.stopPrank();
    }

    /// @notice redeem() always reverts with AsyncWithdrawalRequired
    function test_golden_redeem_reverts_async() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);

        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.redeem(400e6, user1, user1);
        vm.stopPrank();
    }

    /// @notice requestClaim(true) settles instantly when cap + liquidity OK
    function test_golden_requestClaimInstant_settles() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);

        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 sharesBefore = vault.balanceOf(user1);

        // Instant claim for 400 shares
        IQueueModule(address(vault)).requestClaim(true, 400e6);
        vm.stopPrank();

        uint256 sharesAfter = vault.balanceOf(user1);
        uint256 usdcAfter = usdc.balanceOf(user1);

        assertEq(sharesBefore - sharesAfter, 400e6, "Golden: 400 shares consumed");
        assertGt(usdcAfter, usdcBefore, "Golden: user received USDC");
        assertEq(sharesAfter, 600e6, "Golden: remaining shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PREVIEW FUNCTIONS - EXACT VALUES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice previewWithdraw returns shares needed for given assets
    function test_golden_previewWithdraw() public {
        // Setup: deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 previewShares = vault.previewWithdraw(400e6);
        assertEq(previewShares, 400e6, "Golden: previewWithdraw 1:1");
    }

    /// @notice previewRedeem returns assets for given shares
    function test_golden_previewRedeem() public {
        // Setup: deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 previewAssets = vault.previewRedeem(400e6);
        assertEq(previewAssets, 400e6, "Golden: previewRedeem 1:1");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONVERSION FUNCTIONS - EXACT VALUES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice convertToShares returns correct value
    function test_golden_convertToShares() public {
        // Setup: deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        assertEq(vault.convertToShares(100e6), 100e6, "Golden: convertToShares 1:1");
        assertEq(vault.convertToShares(500e6), 500e6, "Golden: convertToShares 500");
    }

    /// @notice convertToAssets returns correct value
    function test_golden_convertToAssets() public {
        // Setup: deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        assertEq(vault.convertToAssets(100e6), 100e6, "Golden: convertToAssets 1:1");
        assertEq(vault.convertToAssets(500e6), 500e6, "Golden: convertToAssets 500");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MAX FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice maxDeposit returns correct value
    function test_golden_maxDeposit() public view {
        // With no cap, should be max uint
        assertEq(vault.maxDeposit(user1), type(uint256).max, "Golden: maxDeposit");
    }

    /// @notice maxMint returns correct value
    function test_golden_maxMint() public view {
        assertEq(vault.maxMint(user1), type(uint256).max, "Golden: maxMint");
    }

    function test_minDeposit_enforced_on_deposit() public {
        params.setDepositLimits(0, 0, 100e6);

        vm.startPrank(user1);
        usdc.approve(address(vault), 99e6);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Module.DepositBelowMinimum.selector, 99e6, 100e6)
        );
        vault.deposit(99e6, user1);
        vm.stopPrank();
    }

    function test_vaultDepositCap_enforced_and_reflected_in_maxDeposit() public {
        params.setDepositLimits(1_000e6, 0, 0);

        vm.startPrank(user1);
        usdc.approve(address(vault), 700e6);
        vault.deposit(700e6, user1);
        vm.stopPrank();

        assertEq(vault.maxDeposit(user2), 300e6, "remaining vault capacity");

        vm.startPrank(user2);
        usdc.approve(address(vault), 301e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Module.VaultDepositCapExceeded.selector, 1_001e6, 1_000e6
            )
        );
        vault.deposit(301e6, user2);
        vm.stopPrank();
    }

    function test_userDepositCap_enforced_and_reflected_in_maxDeposit() public {
        params.setDepositLimits(0, 500e6, 0);

        vm.startPrank(user1);
        usdc.approve(address(vault), 400e6);
        vault.deposit(400e6, user1);
        vm.stopPrank();

        assertEq(vault.maxDeposit(user1), 100e6, "remaining user capacity");

        vm.startPrank(user1);
        usdc.approve(address(vault), 101e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Module.UserDepositCapExceeded.selector, 501e6, 500e6
            )
        );
        vault.deposit(101e6, user1);
        vm.stopPrank();
    }

    /// @notice maxWithdraw returns 0 (queued protocol: withdraw always reverts)
    function test_golden_maxWithdraw() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        assertEq(vault.maxWithdraw(user1), 0, "Golden: maxWithdraw = 0 (queued protocol)");
    }

    /// @notice maxRedeem returns 0 (queued protocol: redeem always reverts)
    function test_golden_maxRedeem() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vm.stopPrank();

        assertEq(vault.maxRedeem(user1), 0, "Golden: maxRedeem = 0 (queued protocol)");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // FULL WITHDRAWAL - DUST PREVENTION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Full instant claim should leave no shares
    function test_golden_fullRedeem_noDust() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);

        // Full instant claim
        uint256 shares = vault.balanceOf(user1);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();

        assertEq(vault.balanceOf(user1), 0, "Golden: no dust shares");
    }

    /// @notice Full instant claim via requestClaim
    function test_golden_fullWithdraw_noDust() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);

        // Full instant claim
        uint256 shares = vault.balanceOf(user1);
        IQueueModule(address(vault)).requestClaim(true, shares);
        vm.stopPrank();

        assertEq(vault.balanceOf(user1), 0, "Golden: no dust after full claim");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ASSET/SHARE INFO
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice asset() returns correct underlying
    function test_golden_asset() public view {
        assertEq(vault.asset(), address(usdc), "Golden: correct asset address");
    }

    /// @notice decimals returns underlying asset decimals (USDC = 6)
    /// @dev ERC4626 standard: decimals should match underlying asset
    function test_golden_decimals() public view {
        assertEq(vault.decimals(), usdc.decimals(), "Vault decimals should match asset decimals");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Zero deposit should revert
    function test_golden_zeroDeposit_reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1e6);

        vm.expectRevert(CoreVault.ZeroAmount.selector);
        vault.deposit(0, user1);
        vm.stopPrank();
    }

    /// @notice Zero mint should revert
    function test_golden_zeroMint_reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1e6);

        vm.expectRevert(CoreVault.ZeroAmount.selector);
        vault.mint(0, user1);
        vm.stopPrank();
    }

    /// @notice Deposit to different receiver works
    function test_golden_depositToReceiver() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);

        uint256 shares = vault.deposit(1000e6, user2); // Deposit to user2
        vm.stopPrank();

        assertEq(vault.balanceOf(user1), 0, "Golden: sender has no shares");
        assertEq(vault.balanceOf(user2), shares, "Golden: receiver has shares");
    }

    /// @notice Withdraw with allowance reverts (queued protocol)
    function test_golden_withdrawWithAllowance() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, user1);
        vault.approve(user2, 500e6);
        vm.stopPrank();

        // withdraw always reverts in queued protocol
        vm.prank(user2);
        vm.expectRevert(ExitEngineLib.AsyncWithdrawalRequired.selector);
        vault.withdraw(500e6, user2, user1);
    }
}
