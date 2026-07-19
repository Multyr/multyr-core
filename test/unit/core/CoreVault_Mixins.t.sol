// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CoreVault } from "../../../src/core/CoreVault.sol";
import { MockUSDCPermit } from "../../helpers/MockUSDCPermit.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ModuleSetter } from "../../helpers/ModuleSetter.sol";
import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";

/**
 * @title CoreVault_Mixins Tests
 * @notice Tests for CoreVault ownership and basic functionality
 * @dev NOTE: The modular CoreVault architecture no longer includes ERC20Permit.
 *      The vault shares do NOT support permit() - users must use approve().
 *      For one-click deposit UX, use Permit2DepositHelper (periphery contract).
 */
contract CoreVaultMixinsTest is Test {
    CoreVault vault;
    MockUSDCPermit usdc;
    MockParamsProvider paramsProvider;

    address owner = address(0xA11CE);
    address feeCollector = address(0xFEE);

    function setUp() public {
        usdc = new MockUSDCPermit();
        paramsProvider = new MockParamsProvider();

        // Deploy with new 6-param constructor (via CoreHarness for setBufferManagerUnsafe)
        CoreHarness _harness = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "VaultUSDC",
            "vUSDC",
            owner,
            feeCollector,
            address(paramsProvider)
        );
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(_harness));
        _harness.setBufferManagerUnsafe(address(mockBM));
        vault = _harness;
    }

    // ============================================================================
    // NOTE: All ERC20Permit tests have been REMOVED because the modular CoreVault
    // architecture no longer inherits ERC20Permit.
    //
    // The vault shares do NOT support gasless permit() signatures.
    // Users must use the standard ERC20 approve() flow for share transfers,
    // OR use Permit2DepositHelper for one-click deposits via Permit2.
    //
    // Original tests removed:
    //   - test_sharesPermit_basic_allowance_and_nonce_and_replay
    //   - test_sharesPermit_bad_v_reverts
    //   - test_sharesPermit_expired_deadline_reverts
    //   - test_sharesPermit_wrong_signer_reverts
    //   - test_sharesPermit_zero_value_keeps_allowance_zero
    //   - test_sharesPermit_allowsTransferFrom
    // ============================================================================

    function test_ownable2step_syncs_roles_owner() public {
        address newOwner = address(0x1234);
        // Start transfer by current owner
        vm.prank(owner);
        vault.beginOwnerTransfer(newOwner);
        // Accept as newOwner
        vm.prank(newOwner);
        vault.acceptOwnerTransfer();
        // Roles.owner must be updated
        assertEq(vault.owner(), newOwner);
    }

    /// @notice Verify vault was deployed correctly without ERC20Permit
    function test_vault_basic_deploy() public view {
        assertEq(address(vault.asset()), address(usdc), "Asset should be USDC");
        assertEq(vault.name(), "VaultUSDC", "Name should match");
        assertEq(vault.symbol(), "vUSDC", "Symbol should match");
        assertEq(vault.owner(), owner, "Owner should match");
    }

    /// @notice Verify standard ERC20 approve/transferFrom still works
    function test_vault_standard_approve_transfer() public {
        uint256 pkUser = 0xAABB;
        address user = vm.addr(pkUser);
        address spender = address(0xBEEF);

        // User deposits to get shares
        usdc.mint(user, 500e6);
        vm.prank(user);
        usdc.approve(address(vault), 500e6);
        vm.prank(user);
        uint256 shares = vault.deposit(100e6, user);

        // User approves spender using standard ERC20 approve (not permit)
        vm.prank(user);
        vault.approve(spender, shares);

        // Verify allowance
        assertEq(vault.allowance(user, spender), shares, "Allowance should be set");

        // Spender can transferFrom
        vm.prank(spender);
        require(vault.transferFrom(user, spender, shares), "transferFrom fail");
        assertEq(vault.balanceOf(spender), shares, "Spender should have shares");
    }
}
