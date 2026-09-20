// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {GlobalConfig} from "../../../src/core/config/GlobalConfig.sol";
import {GlobalConfigMigrated} from "../../../script/helpers/GlobalConfigMigration.sol";
import {IParamsProvider} from "../../../src/interfaces/IParamsProvider.sol";
contract GlobalConfigMigrationTest is Test {
 function testPreserveDefaultsOverridesOracleAndGovernor() public {
  GlobalConfig old=new GlobalConfig(address(this),5,25,1700,2 hours,6,250,1000,3600);
  address v=address(this);address asset=address(old);
  old.setVaultDepositLimits(v,200e6,50e6,1e6);
  old.setVaultWithdrawalOverride(v,GlobalConfig.WithdrawalConfig(2500,0,0,2e6,17));
  old.setVaultDynamicCapOverride(v,GlobalConfig.DynamicCapConfig(100,2500,80e6,true));
  old.setVaultFeeOverride(v,7,30,1500);
  old.setAssetOracleConfig(asset,address(this),7200);
  old.setDefaultGovCaps(700,3e17,300,50,60,400,5e6,555555,2000);
  old.setVaultGovCaps(v,900,4e17,350,70,80,500,6e6,666666,2500);
  old.setGovernor(address(0xBEEF));
  GlobalConfigMigrated next=new GlobalConfigMigrated(address(old),v,asset);
  assertEq(next.governor(),address(0xBEEF));
  assertEq(keccak256(abi.encode(old.getFeeParams(v))),keccak256(abi.encode(next.getFeeParams(v))));
  assertEq(keccak256(abi.encode(old.getWithdrawalParams(v))),keccak256(abi.encode(next.getWithdrawalParams(v))));
  assertEq(keccak256(abi.encode(old.getDynamicCapParams(v))),keccak256(abi.encode(next.getDynamicCapParams(v))));
  assertEq(keccak256(abi.encode(old.getDepositLimits(v))),keccak256(abi.encode(next.getDepositLimits(v))));
  assertEq(next.minDeployAmount(v),6e6);assertEq(next.minDeployAmount(address(0)),5e6);
  assertEq(next.oracleFor(asset),address(this));
  for(uint8 i;i<=14;i++)assertEq(next.hasOverride(v,GlobalConfig.ParamType(i)),old.hasOverride(v,GlobalConfig.ParamType(i)));
  vm.prank(address(0xBEEF));next.setVaultQueueOverride(v,GlobalConfig.QueueConfig(10,3600,86400));
  assertEq(next.getQueueParams(v).epochDuration,86400);assertEq(old.getQueueParams(v).epochDuration,604800);
 }
 function testRejectActiveUninventoriedAdapterPolicy() public {
  GlobalConfig old=new GlobalConfig(address(this),0,0,0,0,1,0,1,60);
  old.setVaultAdapterOverride(address(this),address(7),true,100);
  vm.expectRevert(bytes("adapter policy needs explicit migration"));
  new GlobalConfigMigrated(address(old),address(this),address(old));
 }
}
