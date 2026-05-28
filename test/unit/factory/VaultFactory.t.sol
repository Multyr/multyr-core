// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { VaultFactory } from "../../../src/factory/VaultFactory.sol";
import { DeployTypes } from "../../../src/libs/DeployTypes.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract MockVault {
    address public immutable asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

contract MockAsset {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
}

contract VaultFactory_Unit_Test is Test {
    VaultFactory public factory;
    MockAsset public mockAsset;
    address public owner;
    address public user;

    event VaultDeployed(
        address indexed vault,
        address indexed asset,
        address indexed owner,
        address feeCollector,
        string name,
        string symbol
    );
    event VaultDeprecated(address indexed vault);
    event VaultRemoved(address indexed vault);
    event VaultStatusChanged(address indexed vault, string status, string note);

    function setUp() public {
        owner = address(this);
        user = address(0x1234);
        factory = new VaultFactory();
        mockAsset = new MockAsset();
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(factory.owner(), owner, "owner should be deployer");
    }

    function test_constructor_emptyVaultsList() public view {
        assertEq(factory.deployedVaultsCount(), 0, "should start empty");
    }

    // ============ createVault Tests ============

    function test_createVault_reverts() public {
        vm.expectRevert(VaultFactory.UseOffchainDeployer.selector);
        factory.createVault(bytes(""));
    }

    function test_createVaultDeterministic_reverts() public {
        vm.expectRevert(VaultFactory.UseOffchainDeployer.selector);
        factory.createVaultDeterministic(bytes(""), bytes32(0));
    }

    // ============ registerVault Tests ============

    function test_registerVault_onlyOwner() public {
        MockVault vault = new MockVault(address(mockAsset));
        DeployTypes.VaultRegistrationConfig memory cfg = _makeConfig();

        vm.prank(user);
        vm.expectRevert(VaultFactory.NotOwner.selector);
        factory.registerVault(address(vault), abi.encode(cfg));
    }

    function test_registerVault_rejectsZeroAddress() public {
        DeployTypes.VaultRegistrationConfig memory cfg = _makeConfig();

        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.registerVault(address(0), abi.encode(cfg));
    }

    function test_registerVault_rejectsAssetMismatch() public {
        MockAsset wrongAsset = new MockAsset();
        MockVault vault = new MockVault(address(wrongAsset));
        DeployTypes.VaultRegistrationConfig memory cfg = _makeConfig();

        vm.expectRevert(VaultFactory.AssetMismatch.selector);
        factory.registerVault(address(vault), abi.encode(cfg));
    }

    function test_registerVault_success() public {
        MockVault vault = new MockVault(address(mockAsset));
        DeployTypes.VaultRegistrationConfig memory cfg = _makeConfig();

        vm.expectEmit(true, true, true, true);
        emit VaultDeployed(
            address(vault), address(mockAsset), cfg.owner, cfg.feeCollector, cfg.name, cfg.symbol
        );

        factory.registerVault(address(vault), abi.encode(cfg));

        assertEq(factory.deployedVaultsCount(), 1, "count should be 1");
        assertEq(factory.deployedVaults(0), address(vault), "vault should be at index 0");
        assertEq(factory.vaultIndexPlusOne(address(vault)), 1, "index should be tracked");
        assertTrue(factory.isDeployedVault(address(vault)), "should be registered");
    }

    function test_registerVault_rejectsDuplicate() public {
        MockVault vault = new MockVault(address(mockAsset));
        DeployTypes.VaultRegistrationConfig memory cfg = _makeConfig();

        factory.registerVault(address(vault), abi.encode(cfg));

        vm.expectRevert(VaultFactory.VaultAlreadyRegistered.selector);
        factory.registerVault(address(vault), abi.encode(cfg));
    }

    function test_registerVault_multipleVaults() public {
        MockVault vault1 = new MockVault(address(mockAsset));
        MockVault vault2 = new MockVault(address(mockAsset));
        MockVault vault3 = new MockVault(address(mockAsset));
        DeployTypes.VaultRegistrationConfig memory cfg = _makeConfig();

        factory.registerVault(address(vault1), abi.encode(cfg));
        factory.registerVault(address(vault2), abi.encode(cfg));
        factory.registerVault(address(vault3), abi.encode(cfg));

        assertEq(factory.deployedVaultsCount(), 3, "count should be 3");

        address[] memory vaults = factory.getDeployedVaults();
        assertEq(vaults.length, 3, "array length should be 3");
        assertEq(vaults[0], address(vault1));
        assertEq(vaults[1], address(vault2));
        assertEq(vaults[2], address(vault3));
        assertEq(factory.vaultIndexPlusOne(address(vault1)), 1);
        assertEq(factory.vaultIndexPlusOne(address(vault2)), 2);
        assertEq(factory.vaultIndexPlusOne(address(vault3)), 3);
    }

    // ============ View Function Tests ============

    function test_deployedVaultsCount_empty() public view {
        assertEq(factory.deployedVaultsCount(), 0);
    }

    function test_getDeployedVaults_empty() public view {
        address[] memory vaults = factory.getDeployedVaults();
        assertEq(vaults.length, 0);
    }

    function test_isDeployedVault_false() public view {
        assertFalse(factory.isDeployedVault(address(0x999)));
    }

    function test_isDeployedVault_true() public {
        MockVault vault = new MockVault(address(mockAsset));
        factory.registerVault(address(vault), abi.encode(_makeConfig()));
        assertTrue(factory.isDeployedVault(address(vault)));
    }

    // ============ Fuzz Tests ============

    function testFuzz_registerVault_multipleRegistrations(uint8 count) public {
        vm.assume(count > 0 && count <= 20);

        for (uint8 i = 0; i < count; i++) {
            MockVault vault = new MockVault(address(mockAsset));
            factory.registerVault(address(vault), abi.encode(_makeConfig()));
        }

        assertEq(factory.deployedVaultsCount(), count);
        assertEq(factory.getDeployedVaults().length, count);
    }

    function testFuzz_isDeployedVault_randomAddress(address random) public view {
        // Random address should not be deployed
        assertFalse(factory.isDeployedVault(random));
    }

    // ============ deprecateVault Tests ============

    function test_deprecateVault_emits_event() public {
        MockVault vault = new MockVault(address(mockAsset));
        factory.registerVault(address(vault), abi.encode(_makeConfig()));

        vm.expectEmit(true, false, false, false);
        emit VaultDeprecated(address(vault));
        factory.deprecateVault(address(vault));
    }

    function test_deprecateVault_reverts_nonOwner() public {
        vm.prank(user);
        vm.expectRevert(VaultFactory.NotOwner.selector);
        factory.deprecateVault(address(0x123));
    }

    function test_deprecateVault_reverts_zeroAddress() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.deprecateVault(address(0));
    }

    // ============ removeVault Tests ============

    function test_removeVault_removes_and_emits() public {
        MockVault vault = new MockVault(address(mockAsset));
        factory.registerVault(address(vault), abi.encode(_makeConfig()));
        assertTrue(factory.isDeployedVault(address(vault)));

        vm.expectEmit(true, false, false, false);
        emit VaultRemoved(address(vault));
        factory.removeVault(address(vault));

        assertFalse(factory.isDeployedVault(address(vault)));
        assertEq(factory.vaultIndexPlusOne(address(vault)), 0);
        assertEq(factory.deployedVaultsCount(), 0);
    }

    function test_removeVault_swapAndPop_preserves_others() public {
        MockVault v1 = new MockVault(address(mockAsset));
        MockVault v2 = new MockVault(address(mockAsset));
        MockVault v3 = new MockVault(address(mockAsset));
        factory.registerVault(address(v1), abi.encode(_makeConfig()));
        factory.registerVault(address(v2), abi.encode(_makeConfig()));
        factory.registerVault(address(v3), abi.encode(_makeConfig()));

        factory.removeVault(address(v1));

        assertEq(factory.deployedVaultsCount(), 2);
        assertFalse(factory.isDeployedVault(address(v1)));
        assertTrue(factory.isDeployedVault(address(v2)));
        assertTrue(factory.isDeployedVault(address(v3)));
        assertEq(factory.deployedVaults(0), address(v3));
        assertEq(factory.deployedVaults(1), address(v2));
        assertEq(factory.vaultIndexPlusOne(address(v1)), 0);
        assertEq(factory.vaultIndexPlusOne(address(v2)), 2);
        assertEq(factory.vaultIndexPlusOne(address(v3)), 1);
    }

    function test_removeVault_reverts_nonOwner() public {
        vm.prank(user);
        vm.expectRevert(VaultFactory.NotOwner.selector);
        factory.removeVault(address(0x123));
    }

    function test_removeVault_reverts_notFound() public {
        vm.expectRevert(VaultFactory.VaultNotFound.selector);
        factory.removeVault(address(0x999));
    }

    function test_removeVault_reverts_zeroAddress() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.removeVault(address(0));
    }

    // ============ setVaultStatus Tests ============

    function test_setVaultStatus_emits_event() public {
        MockVault vault = new MockVault(address(mockAsset));
        factory.registerVault(address(vault), abi.encode(_makeConfig()));

        vm.expectEmit(true, false, false, true);
        emit VaultStatusChanged(address(vault), "WITHDRAW_ONLY", "Migration to v4");
        factory.setVaultStatus(address(vault), "WITHDRAW_ONLY", "Migration to v4");
    }

    function test_setVaultStatus_reverts_nonOwner() public {
        vm.prank(user);
        vm.expectRevert(VaultFactory.NotOwner.selector);
        factory.setVaultStatus(address(0x123), "HOLD", "");
    }

    function test_setVaultStatus_reverts_zeroAddress() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setVaultStatus(address(0), "HOLD", "");
    }

    // ============ Helpers ============

    function _makeConfig() internal view returns (DeployTypes.VaultRegistrationConfig memory) {
        return DeployTypes.VaultRegistrationConfig({
            asset: IERC20Metadata(address(mockAsset)),
            name: "Test Vault",
            symbol: "tVLT",
            owner: address(0xABCD),
            feeCollector: address(0xFFFF)
        });
    }
}
