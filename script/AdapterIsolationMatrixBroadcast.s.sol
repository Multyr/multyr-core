// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

/// @notice Minimal ABI for the live "Multyr Strategies" USDC lending allocation
///         engine on Arbitrum One. Not part of this repo's src/ tree (separately
///         deployed package) -- signatures pulled from verified on-chain source.
interface ILendingAdapter {
    function totalAssets() external view returns (uint256);
    function currentAPYBps() external view returns (uint16);
    function maxCapacity() external view returns (uint256);
    function externalMarketTVL() external view returns (uint256);
}

interface IUsdcMultiLendingVault {
    function toggleAdapter(address adapter, bool on) external;
    function enabled(address adapter) external view returns (bool);
    function positionAssets(address adapter) external view returns (uint256);
    function idleCash() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function deployIdle() external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title AdapterIsolationMatrixBroadcast
/// @notice Same adapter-by-adapter isolation flow as test/fork/AdapterIsolationMatrix.t.sol,
///         but run as real broadcast transactions against a LOCAL anvil fork of Arbitrum
///         One so the result is real transaction hashes and receipts, not just a trace log.
/// @dev    MUST be run with --rpc-url pointing at a local anvil instance
///         (`anvil --fork-url <arbitrum-rpc> --auto-impersonate`), NEVER at real
///         Arbitrum mainnet. `--auto-impersonate` lets anvil accept eth_sendTransaction
///         from RootTimelock / StrategyUpkeep / the USDC whale below with no private key.
///         Euler is intentionally excluded and never touched (see prior fork-test finding:
///         its maxCapacity() is 0 on live mainnet, so it fails deployment regardless).
///
///         Runs ONE adapter round per invocation (ROUND_IDX env var, 0-5) rather than
///         looping all 6 in a single script run. A forge script's local simulated
///         block.timestamp does not reliably track the real target node's clock across
///         multiple vm.startBroadcast/stopBroadcast segments, so an in-script time-skip
///         between rounds isn't safe against the vault's real 300s deployIdle() cooldown.
///         Advance the real node's clock from the shell (cast rpc evm_increaseTime +
///         evm_mine) between invocations instead -- each invocation freshly forks the
///         node's actual current state, so there's no local/real clock drift to manage.
contract AdapterIsolationMatrixBroadcast is Script {
    address constant VAULT = 0x2ca30120C828Fc136d348234f7e68116572DD83E; // UsdcMultiLendingVault
    address constant TIMELOCK = 0xE2812E869F8005397130CCDF1aaabd75447844df; // RootTimelock (DEFAULT_ADMIN_ROLE)
    address constant STRATEGY_UPKEEP = 0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550; // KEEPER_ROLE holder
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WHALE = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // large live Arbitrum USDC holder, forked balance

    address constant AAVE = 0x2A5097977418C4Dc616f963Caae11d8f76325F2a;
    address constant MORPHO = 0xb6B34A0d49Cda4d0E0B515C4aA17f2642e0792B5;
    address constant COMET = 0x273c429DD929830033BBE60AB08547ADe60BD74c;
    address constant DOLOMITE = 0x7aA2F4Ce5c7031c34f2dB681045Da7eA751a651f;
    address constant FLUID = 0xa5044692678aeB49dEF903a441D3f84878367Ef5;
    address constant VENUS = 0x86e262C02cA6245D6bDF3901cF4d063cfB0d2Bd5;
    // EULER intentionally omitted -- known dead capacity, excluded per instruction.

    uint256 constant SEED_USDC = 1_000e6;

    function run() external {
        address[6] memory adapters = [AAVE, MORPHO, COMET, DOLOMITE, FLUID, VENUS];
        string[6] memory labels = ["Aave", "Morpho", "Comet", "Dolomite", "Fluid", "Venus"];

        uint256 idx = vm.envUint("ROUND_IDX");
        require(idx < 6, "ROUND_IDX must be 0..5");

        IUsdcMultiLendingVault vault = IUsdcMultiLendingVault(VAULT);
        require(block.chainid == 42161, "point --rpc-url at a local anvil fork of Arbitrum One");

        address target = adapters[idx];
        console2.log("===== ROUND:", labels[idx]);

        uint256 taBefore = ILendingAdapter(target).totalAssets();

        vm.startBroadcast(TIMELOCK);
        for (uint256 j; j < 6; ++j) {
            vault.toggleAdapter(adapters[j], j == idx);
        }
        vm.stopBroadcast();
        console2.log("[governance] only", labels[idx], "enabled among the 6 (Euler left untouched)");

        vm.startBroadcast(WHALE);
        bool sent = IERC20Min(USDC).transfer(VAULT, SEED_USDC);
        vm.stopBroadcast();
        require(sent, "seed transfer failed");
        console2.log("[seed] whale transferred idle USDC:", SEED_USDC);

        vm.startBroadcast(STRATEGY_UPKEEP);
        vault.deployIdle();
        vm.stopBroadcast();

        uint256 taAfter = ILendingAdapter(target).totalAssets();
        console2.log("[accounting] totalAssets before/after:", taBefore, taAfter);
        console2.log("[accounting] positionAssets:", vault.positionAssets(target));
        console2.log("[accounting] externalMarketTVL:", ILendingAdapter(target).externalMarketTVL());
        console2.log("[capacity] maxCapacity:", ILendingAdapter(target).maxCapacity());
        console2.log("[rate] currentAPYBps:", ILendingAdapter(target).currentAPYBps());
        console2.log("[vault] totalAssets/idleCash:", vault.totalAssets(), vault.idleCash());

        if (taAfter > taBefore) {
            console2.log("===== RESULT: PASS -", labels[idx]);
        } else {
            console2.log("===== RESULT: FAIL -", labels[idx]);
        }
    }
}
