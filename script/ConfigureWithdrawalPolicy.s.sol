// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Script,console2} from "forge-std/Script.sol";
import {GlobalConfig} from "../src/core/config/GlobalConfig.sol";
import {IParamsProvider} from "../src/interfaces/IParamsProvider.sol";
interface PolicyCore {function params() external view returns(address);function asset() external view returns(address);}
interface PolicyTimelock {
 function getMinDelay() external view returns(uint256);
 function hasRole(bytes32,address) external view returns(bool);
 function scheduleBatch(address[] calldata,uint256[] calldata,bytes[] calldata,bytes32,bytes32,uint256) external;
 function executeBatch(address[] calldata,uint256[] calldata,bytes[] calldata,bytes32,bytes32) external payable;
}
/// @notice Permanent deposit/exit policy correction. No temporary floor or restoration.
/// @dev Preserves deposit caps, withdrawal caps, lock period and queue configuration.
contract ConfigureWithdrawalPolicy is Script {
 address constant CORE=0x4575Ec0dD1ED08FD4F426665E5B56442594189bb;
 address constant EXPECTED_CONFIG=0x16968cA72bE6CBfCaC8A8a87349EE5706f771a2e;
 address constant ROOT=0xE2812E869F8005397130CCDF1aaabd75447844df;
 address constant SIGNER=0x908756f36954f2853134259B8846c49F90E84ECe;
 function run() external {
  require(block.chainid==42161,"Arbitrum only");
  address config=PolicyCore(CORE).params();require(config==EXPECTED_CONFIG,"config changed; review");
  require(PolicyCore(CORE).asset()==0xaf88d065e77c8cC2239327C5EDb3A432268e5831,"native USDC required");
  GlobalConfig cfg=GlobalConfig(config);require(cfg.governor()==ROOT,"governor changed");
  PolicyTimelock tl=PolicyTimelock(ROOT);
  require(tl.getMinDelay()==0,"schedule separately for nonzero delay");
  require(tl.hasRole(keccak256("PROPOSER_ROLE"),SIGNER)&&tl.hasRole(keccak256("EXECUTOR_ROLE"),SIGNER),"missing roles");
  IParamsProvider.WithdrawalParams memory w=cfg.getWithdrawalParams(CORE);
  IParamsProvider.DepositLimits memory d=cfg.getDepositLimits(CORE);
  bytes32 queueBefore=keccak256(abi.encode(cfg.getQueueParams(CORE)));
  if(w.minClaimAmount==0 && d.minDepositAmount==100e6){console2.log("Policy already correct");return;}
  address[] memory targets=new address[](2);uint256[] memory values=new uint256[](2);bytes[] memory calls=new bytes[](2);
  targets[0]=config;targets[1]=config;
  calls[0]=abi.encodeCall(GlobalConfig.setVaultWithdrawalOverride,(CORE,GlobalConfig.WithdrawalConfig(w.capPerEpochBps,w.maxWithdrawalPerBlock,w.maxWithdrawalPerTx,0,w.lockPeriod)));
  calls[1]=abi.encodeCall(GlobalConfig.setVaultDepositLimits,(CORE,d.vaultDepositCap,d.userDepositCap,100e6));
  bytes32 salt=keccak256(abi.encode("PermanentDeposit100ExitNoFloor",CORE,config,block.number));
  // Supply the governance signer via forge --account for broadcast. Simulation needs no key.
  vm.startBroadcast(SIGNER);
  tl.scheduleBatch(targets,values,calls,bytes32(0),salt,0);
  tl.executeBatch(targets,values,calls,bytes32(0),salt);
  vm.stopBroadcast();
  w.minClaimAmount=0;d.minDepositAmount=100e6;
  require(keccak256(abi.encode(cfg.getWithdrawalParams(CORE)))==keccak256(abi.encode(w)),"withdrawal mismatch");
  require(keccak256(abi.encode(cfg.getDepositLimits(CORE)))==keccak256(abi.encode(d)),"deposit mismatch");
  require(keccak256(abi.encode(cfg.getQueueParams(CORE)))==queueBefore,"queue changed");
  console2.log("Minimum deposit raw USDC",uint256(100e6));console2.log("Minimum claim raw USDC",uint256(0));
 }
}
