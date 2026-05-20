// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { MockUSDCPermit } from "../../helpers/MockUSDCPermit.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title MockERC20FailTransfer
 * @notice Mock token that returns false on transfer (for SkimMixin testing)
 */
contract MockERC20FailTransfer {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false; // Always fail
    }
}

interface IERC20PermitLike {
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/**
 * @title CoreVault_PermitOpsAndSkim Tests
 * @notice Tests for permit operations and skim functionality
 * @dev NOTE: The new modular CoreVault architecture does not include:
 *      - depositWithPermit
 *      - withdrawWithPermit
 *      - redeemWithPermit
 *      - skim
 *      - multicall
 *      These functions were part of the old monolithic architecture.
 *      Tests below are commented out as they are not applicable to the new design.
 */
contract CoreVaultPermitOpsAndSkimTest is Test {
    CoreVault public vault;
    MockUSDCPermit public usdc;
    MockERC20FailTransfer public failToken;

    address public owner = address(0xA11CE);
    address public guardian = address(0xB0B);
    address public treasury = address(0xFEE);
    address public spender = address(0x5678);

    uint256 constant USER_PK = 0xBEEF;
    address public user; // Derived from USER_PK

    event Skimmed(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        user = vm.addr(USER_PK); // Derive address from private key

        usdc = new MockUSDCPermit();
        failToken = new MockERC20FailTransfer();

        // Deploy MockParamsProvider
        MockParamsProvider params = new MockParamsProvider();

        // Deploy vault with 6-param constructor (new modular architecture)
        vm.prank(owner);
        vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "VaultUSDC",
            "vUSDC",
            owner,
            treasury, // feeCollector
            address(params)
        );

        // NOTE: No modules wired here since the permit/skim functions
        // are not part of the new modular architecture

        usdc.mint(user, 10_000_000e6);
    }

    // ============================================================================
    // NOTE: All tests below are commented out because the new modular CoreVault
    // architecture does not include the following functions:
    //   - depositWithPermit
    //   - withdrawWithPermit
    //   - redeemWithPermit
    //   - skim
    //   - multicall
    //
    // These functions were part of the old monolithic PermitOpsMixin and SkimMixin.
    // The new architecture uses a modular design with separate modules.
    // ============================================================================

    /*
    // ============ PermitOpsMixin Tests ============
    // (Not applicable - functions removed from new architecture)

    /// @notice Helper to sign EIP-2612 permits
    function _signPermit(
        address token,
        uint256 pk,
        address owner_,
        address spender_,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 DOMAIN_SEPARATOR = IERC20PermitLike(token).DOMAIN_SEPARATOR();
        uint256 nonce = IERC20PermitLike(token).nonces(owner_);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner_, spender_, value, nonce, deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    /// @notice Test 1: withdrawWithPermit (5-arg) uses shares permit correctly
    function test_permitOps_withdrawWithPermit_five_args_uses_shares_permit() public {
        // Setup: User deposits
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // User signs permit for shares (not assets)
        uint256 assetsToWithdraw = 500e6;
        uint256 neededShares = vault.previewWithdraw(assetsToWithdraw);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            address(vault),
            USER_PK,
            user,
            spender,
            neededShares,
            block.timestamp + 1 days
        );

        // Spender calls withdrawWithPermit on behalf of user
        vm.prank(spender);
        uint256 sharesOut = vault.withdrawWithPermit(
            assetsToWithdraw,
            user,      // receiver
            user,      // owner
            block.timestamp + 1 days,
            v, r, s
        );

        // Verify
        assertGt(sharesOut, 0, "Should burn shares");
    }

    /// @notice Test 2: redeemWithPermit reverts when receiver != msg.sender (ONLY_RECEIVER guard)
    function test_permitOps_redeemWithPermit_non_receiver_caller_reverts() public {
        // Setup: User deposits
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1000e6, user);
        vm.stopPrank();

        // Spender tries to call redeemWithPermit with receiver != msg.sender
        address receiver = address(0x9999);
        vm.prank(spender);
        vm.expectRevert("ONLY_RECEIVER");
        vault.redeemWithPermit(shares, receiver);
    }

    /// @notice Test 3: depositWithPermit signature replay fails (nonce increment)
    function test_permitOps_depositWithPermit_signature_replay_fails() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            address(usdc),
            USER_PK,
            user,
            address(vault),
            1_000e6,
            block.timestamp + 1 days
        );

        // First call succeeds
        vm.prank(user);
        vault.depositWithPermit(1_000e6, user, block.timestamp + 1 days, v, r, s);

        // Second call with same signature fails (nonce mismatch)
        vm.prank(user);
        vm.expectRevert();
        vault.depositWithPermit(1_000e6, user, block.timestamp + 1 days, v, r, s);
    }

    /// @notice Test 4: withdrawWithPermit handles exchange rate changes correctly
    function test_permitOps_withdrawWithPermit_exchange_rate_change_handles_correctly() public {
        // Setup: User deposits
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        // Donate assets to change exchange rate
        usdc.mint(address(vault), 500e6);

        // Sign permit
        uint256 neededShares = vault.previewWithdraw(400e6);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            address(vault),
            USER_PK,
            user,
            spender,
            neededShares,
            block.timestamp + 1 days
        );

        // withdrawWithPermit recomputes neededShares at call time
        vm.prank(spender);
        uint256 sharesOut = vault.withdrawWithPermit(
            400e6,
            user,
            user,
            block.timestamp + 1 days,
            v, r, s
        );

        assertGt(sharesOut, 0, "Should withdraw successfully");
    }

    // ============ SkimMixin Tests ============
    // (Not applicable - skim function removed from new architecture)

    /// @notice Test 5: skim with zero balance reverts (NO_BALANCE guard)
    function test_skim_zero_balance_reverts() public {
        // Deploy another token but don't send any to vault
        MockUSDCPermit otherToken = new MockUSDCPermit();
        assertEq(otherToken.balanceOf(address(vault)), 0, "Vault has zero balance");

        // Try to skim
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NoBalance()"));
        vault.skim(address(otherToken), owner);
    }

    /// @notice Test 6: skim with failing transfer reverts (TRANSFER_FAIL guard)
    function test_skim_transfer_failure_reverts() public {
        // Send failToken to vault
        failToken.mint(address(vault), 100e6);
        assertGt(failToken.balanceOf(address(vault)), 0, "Vault has balance");

        // Try to skim - transfer will return false
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("TransferFailed()"));
        vault.skim(address(failToken), owner);
    }

    /// @notice Test 7: skim emits Skimmed event
    function test_skim_emits_Skimmed_event() public {
        // Send token to vault
        MockUSDCPermit otherToken = new MockUSDCPermit();
        uint256 amount = 123e6;
        otherToken.mint(address(vault), amount);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit Skimmed(address(otherToken), owner, amount);

        vm.prank(owner);
        vault.skim(address(otherToken), owner);
    }

    /// @notice Test 8: skim multiple tokens in sequence
    function test_skim_multiple_tokens_in_sequence() public {
        MockUSDCPermit token1 = new MockUSDCPermit();
        MockUSDCPermit token2 = new MockUSDCPermit();

        token1.mint(address(vault), 100e6);
        token2.mint(address(vault), 200e6);

        // Skim token1
        vm.prank(owner);
        vault.skim(address(token1), owner);
        assertEq(token1.balanceOf(owner), 100e6, "Token1 skimmed");

        // Skim token2
        vm.prank(owner);
        vault.skim(address(token2), owner);
        assertEq(token2.balanceOf(owner), 200e6, "Token2 skimmed");
    }

    /// @notice Test 9: skim to different address than caller
    function test_skim_to_different_address_than_caller() public {
        MockUSDCPermit otherToken = new MockUSDCPermit();
        otherToken.mint(address(vault), 500e6);

        address recipient = address(0x7777);

        vm.prank(owner);
        vault.skim(address(otherToken), recipient);

        assertEq(otherToken.balanceOf(recipient), 500e6, "Recipient should receive tokens");
        assertEq(otherToken.balanceOf(owner), 0, "Owner should not receive tokens");
    }

    /// @notice Test 10: Fuzz test - skim with various amounts
    function testFuzz_skim_various_amounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1_000_000_000e6);

        MockUSDCPermit otherToken = new MockUSDCPermit();
        otherToken.mint(address(vault), amount);

        vm.prank(owner);
        vault.skim(address(otherToken), owner);

        assertEq(otherToken.balanceOf(owner), amount, "Owner should receive exact amount");
        assertEq(otherToken.balanceOf(address(vault)), 0, "Vault should be empty");
    }

    /// @notice Test 11: Verify skim cannot be called by non-owner
    function test_skim_non_owner_reverts() public {
        MockUSDCPermit otherToken = new MockUSDCPermit();
        otherToken.mint(address(vault), 100e6);

        // Random user tries to skim
        vm.prank(user);
        vm.expectRevert();
        vault.skim(address(otherToken), user);

        // Guardian tries to skim
        vm.prank(guardian);
        vm.expectRevert();
        vault.skim(address(otherToken), guardian);
    }
    */

    /// @notice Placeholder test to ensure the test contract compiles
    /// @dev All original tests are commented out as they test functions
    ///      not present in the new modular CoreVault architecture
    function test_placeholder_new_architecture() public view {
        // Verify vault was deployed correctly with 6-param constructor
        assertEq(address(vault.asset()), address(usdc), "Asset should be USDC");
        assertEq(vault.name(), "VaultUSDC", "Name should match");
        assertEq(vault.symbol(), "vUSDC", "Symbol should match");
    }
}
