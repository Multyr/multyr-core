// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {GlobalConfig} from "../../../src/core/config/GlobalConfig.sol";
import {IParamsProvider} from "../../../src/interfaces/IParamsProvider.sol";
contract GlobalConfigQueueTest is Test {
 GlobalConfig cfg;address constant VAULT=address(0x123);address constant OTHER=address(0x456);
 function setUp() public {cfg=new GlobalConfig(address(this),50,100,2000,1 days,10,500,1 hours,1 hours);}
 function testVaultOverrideIsolationAndClear() public {
  bytes32 beforeFees=keccak256(abi.encode(cfg.getFeeParams(VAULT)));
  cfg.setVaultQueueOverride(VAULT,GlobalConfig.QueueConfig(10,3600,86400));
  assertTrue(cfg.hasOverride(VAULT,GlobalConfig.ParamType.QUEUE));
  IParamsProvider.QueueParams memory q=cfg.getQueueParams(VAULT);
  assertEq(q.epochDuration,1 days);assertEq(q.cooldownPerClaim,3600);assertEq(q.maxClaimsPerUserPerEpoch,10);
  assertEq(cfg.getQueueParams(OTHER).epochDuration,7 days);
  assertEq(keccak256(abi.encode(cfg.getFeeParams(VAULT))),beforeFees);
  cfg.clearVaultOverride(VAULT,GlobalConfig.ParamType.QUEUE);
  assertEq(cfg.getQueueParams(VAULT).epochDuration,7 days);
 }
 function testOneHourEpochWithPreservedClaimCooldown() public {
  cfg.setVaultQueueOverride(VAULT,GlobalConfig.QueueConfig(10,3600,3600));
  assertEq(cfg.getQueueParams(VAULT).epochDuration,3600);
  assertEq(cfg.getQueueParams(VAULT).cooldownPerClaim,3600);
 }
 function testDefaultsDoNotOverwriteVaultOverride() public {
  cfg.setVaultQueueOverride(VAULT,GlobalConfig.QueueConfig(2,0,1 days));
  cfg.setDefaultQueue(GlobalConfig.QueueConfig(15,100,30 days));
  assertEq(cfg.getQueueParams(VAULT).epochDuration,1 days);
  assertEq(cfg.getQueueParams(OTHER).epochDuration,30 days);
 }
 function testOnlyGovernor() public {
  vm.startPrank(OTHER);vm.expectRevert(GlobalConfig.NotGovernor.selector);
  cfg.setDefaultQueue(GlobalConfig.QueueConfig(10,0,1 days));
  vm.expectRevert(GlobalConfig.NotGovernor.selector);cfg.setVaultQueueOverride(VAULT,GlobalConfig.QueueConfig(10,0,1 days));vm.stopPrank();
 }
 function testRejectInvalidConfiguration() public {
  vm.expectRevert(GlobalConfig.ZeroAddress.selector);cfg.setVaultQueueOverride(address(0),GlobalConfig.QueueConfig(10,0,1 days));
  vm.expectRevert(GlobalConfig.InvalidMaxActions.selector);cfg.setDefaultQueue(GlobalConfig.QueueConfig(0,0,1 days));
  vm.expectRevert(GlobalConfig.InvalidDelay.selector);cfg.setDefaultQueue(GlobalConfig.QueueConfig(10,0,1 hours-1));
  vm.expectRevert(GlobalConfig.InvalidDelay.selector);cfg.setDefaultQueue(GlobalConfig.QueueConfig(10,0,30 days+1));
  vm.expectRevert(GlobalConfig.InvalidDelay.selector);cfg.setVaultQueueOverride(VAULT,GlobalConfig.QueueConfig(10,1 days+1,1 days));
 }
 function testFuzzValidRoundtrip(uint8 count,uint64 duration,uint64 cooldown) public {
  count=uint8(bound(count,1,255));duration=uint64(bound(duration,1 hours,30 days));cooldown=uint64(bound(cooldown,0,duration));
  cfg.setVaultQueueOverride(VAULT,GlobalConfig.QueueConfig(count,cooldown,duration));
  IParamsProvider.QueueParams memory q=cfg.getQueueParams(VAULT);
  assertEq(q.maxClaimsPerUserPerEpoch,count);assertEq(q.cooldownPerClaim,cooldown);assertEq(q.epochDuration,duration);
 }
}
