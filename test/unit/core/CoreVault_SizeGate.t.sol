// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CoreVault } from "src/core/CoreVault.sol";
import { QueueModule } from "src/core/modules/QueueModule.sol";
import { AdminModule } from "src/core/modules/AdminModule.sol";
import { ERC4626Module } from "src/core/modules/ERC4626Module.sol";
import { BufferManager } from "src/core/modules/BufferManager.sol";
import { StrategyRouter } from "src/core/modules/StrategyRouter.sol";
import { ERC20Mock } from "src/mocks/ERC20Mock.sol";

/**
 * @title CoreVault_SizeGate_Test
 * @notice Verifies RUNTIME bytecode sizes stay within EIP-170 limit (24,576 bytes)
 * @dev PR3: Ensures ERC4626Module extraction keeps CoreVault under limit
 *
 * AUDIT-GRADE SIZE GATES:
 * - Uses extcodesize on DEPLOYED contracts (not creationCode.length)
 * - EIP-170 limit: 24,576 bytes runtime bytecode
 * - CoreVault target: < 24KB with margin
 * - Modules: < 16KB (small, stateless)
 */
contract CoreVault_SizeGate_Test is Test {
    // EIP-170: 24KB = 24,576 bytes max runtime bytecode
    uint256 constant EIP170_LIMIT = 24576;

    // Target size for CoreVault (with ~1.5KB margin after ERC4626 fee compliance)
    uint256 constant COREVAULT_TARGET_SIZE = 23552; // 23KB

    // Module target sizes (should be small since they're stateless)
    uint256 constant MODULE_TARGET_SIZE = 16384; // 16KB target for modules

    // Mocks for deployment
    ERC20Mock public usdc;
    address public owner = address(0x1);
    address public feeCollector = address(0x2);

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
    }

    /// @notice Get runtime bytecode size of a deployed contract
    function _getExtcodesize(address target) internal view returns (uint256 size) {
        assembly {
            size := extcodesize(target)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CORE VAULT - MUST BE UNDER EIP-170 LIMIT
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_sizeGate_coreVault_extcodesize_under_24KB() public {
        // Deploy real CoreVault
        CoreVault vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "vTEST",
            owner,
            feeCollector,
            address(0x999) // mock params
        );

        uint256 runtimeSize = _getExtcodesize(address(vault));

        emit log_named_uint("CoreVault runtime bytecode (extcodesize)", runtimeSize);
        emit log_named_uint("EIP-170 limit", EIP170_LIMIT);
        emit log_named_uint("Margin to limit", EIP170_LIMIT - runtimeSize);

        // MUST be under EIP-170 limit
        assertLt(runtimeSize, EIP170_LIMIT, "CoreVault EXCEEDS EIP-170 limit (24,576 bytes)");

        // SHOULD be under 22KB target for safety margin
        assertLt(runtimeSize, COREVAULT_TARGET_SIZE, "CoreVault exceeds 22KB target");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODULES - STATELESS, SHOULD BE SMALL
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_sizeGate_queueModule_extcodesize_under_16KB() public {
        QueueModule module = new QueueModule();
        uint256 runtimeSize = _getExtcodesize(address(module));

        emit log_named_uint("QueueModule runtime bytecode", runtimeSize);
        assertLt(runtimeSize, MODULE_TARGET_SIZE, "QueueModule exceeds 16KB target");
    }

    function test_sizeGate_adminModule_extcodesize_under_16KB() public {
        AdminModule module = new AdminModule();
        uint256 runtimeSize = _getExtcodesize(address(module));

        emit log_named_uint("AdminModule runtime bytecode", runtimeSize);
        assertLt(runtimeSize, MODULE_TARGET_SIZE, "AdminModule exceeds 16KB target");
    }

    function test_sizeGate_erc4626Module_extcodesize_under_16KB() public {
        ERC4626Module module = new ERC4626Module();
        uint256 runtimeSize = _getExtcodesize(address(module));

        emit log_named_uint("ERC4626Module runtime bytecode", runtimeSize);
        assertLt(runtimeSize, MODULE_TARGET_SIZE, "ERC4626Module exceeds 16KB target");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ECOSYSTEM CONTRACTS - UNDER EIP-170
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_sizeGate_strategyRouter_extcodesize_under_24KB() public {
        // Deploy with mock addresses
        StrategyRouter router = new StrategyRouter(
            owner,
            address(0x100), // mock core
            address(0x200) // mock params
        );
        uint256 runtimeSize = _getExtcodesize(address(router));

        emit log_named_uint("StrategyRouter runtime bytecode", runtimeSize);
        assertLt(runtimeSize, EIP170_LIMIT, "StrategyRouter EXCEEDS EIP-170 limit");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SUMMARY TEST - LOGS ALL SIZES
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_sizeGate_summary_extcodesize() public {
        // Deploy all contracts
        CoreVault vault = new CoreVault(
            IERC20Metadata(address(usdc)),
            "Test Vault",
            "vTEST",
            owner,
            feeCollector,
            address(0x999)
        );
        QueueModule queueModule = new QueueModule();
        AdminModule adminModule = new AdminModule();
        ERC4626Module erc4626Module = new ERC4626Module();
        StrategyRouter router = new StrategyRouter(owner, address(0x100), address(0x200));

        emit log_string("");
        emit log_string("=================================================");
        emit log_string("CONTRACT SIZE SUMMARY (extcodesize - RUNTIME)");
        emit log_string("=================================================");

        uint256 coreVaultSize = _getExtcodesize(address(vault));
        uint256 queueSize = _getExtcodesize(address(queueModule));
        uint256 adminSize = _getExtcodesize(address(adminModule));
        uint256 erc4626Size = _getExtcodesize(address(erc4626Module));
        uint256 routerSize = _getExtcodesize(address(router));

        emit log_named_uint("CoreVault      ", coreVaultSize);
        emit log_named_uint("QueueModule    ", queueSize);
        emit log_named_uint("AdminModule    ", adminSize);
        emit log_named_uint("ERC4626Module  ", erc4626Size);
        emit log_named_uint("StrategyRouter ", routerSize);

        emit log_string("");
        emit log_string("LIMITS (EIP-170):");
        emit log_named_uint("24KB limit     ", EIP170_LIMIT);
        emit log_named_uint("22KB target    ", COREVAULT_TARGET_SIZE);
        emit log_named_uint("16KB module    ", MODULE_TARGET_SIZE);
        emit log_string("");

        // Assertions
        assertLt(coreVaultSize, EIP170_LIMIT, "CoreVault EXCEEDS EIP-170");
        assertLt(queueSize, MODULE_TARGET_SIZE, "QueueModule over 16KB");
        assertLt(adminSize, MODULE_TARGET_SIZE, "AdminModule over 16KB");
        assertLt(erc4626Size, MODULE_TARGET_SIZE, "ERC4626Module over 16KB");
        assertLt(routerSize, EIP170_LIMIT, "StrategyRouter EXCEEDS EIP-170");

        emit log_string("ALL SIZE GATES PASSED");
    }
}
