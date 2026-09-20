// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {GlobalConfig} from "../../src/core/config/GlobalConfig.sol";
import {IParamsProvider} from "../../src/interfaces/IParamsProvider.sol";
import {IPriceOracleMiddleware} from "../../src/interfaces/IPriceOracleMiddleware.sol";
/// @notice One-time constructor migration for the inventoried single-vault deployment.
/// Runtime is GlobalConfig; no post-deployment import/storage-write backdoor.
/// All existing fields are imported; the queue change is a separate timelock call.
contract GlobalConfigMigrated is GlobalConfig {
 event ConfigurationImported(address indexed previous,address indexed vault,address indexed asset);
 constructor(address previous,address vault,address asset)
  GlobalConfig(msg.sender,0,0,0,0,1,0,1,60) {
  require(previous.code.length>0 && vault.code.length>0 && asset.code.length>0,"invalid migration addresses");
  governor=abi.decode(_read(previous,abi.encodeWithSignature("governor()")),(address));
  version=abi.decode(_read(previous,abi.encodeWithSignature("version()")),(uint16));
  defaultFees=abi.decode(_read(previous,abi.encodeWithSignature("defaultFees()")),(FeeConfig));
  defaultWithdrawal=abi.decode(_read(previous,abi.encodeWithSignature("defaultWithdrawal()")),(WithdrawalConfig));
  defaultDynamicCap=abi.decode(_read(previous,abi.encodeWithSignature("defaultDynamicCap()")),(DynamicCapConfig));
  defaultQueue=abi.decode(_read(previous,abi.encodeWithSignature("defaultQueue()")),(QueueConfig));
  defaultSecurity=abi.decode(_read(previous,abi.encodeWithSignature("defaultSecurity()")),(SecurityConfig));
  defaultBuffer=abi.decode(_read(previous,abi.encodeWithSignature("defaultBuffer()")),(BufferConfig));
  defaultStrategy=abi.decode(_read(previous,abi.encodeWithSignature("defaultStrategy()")),(StrategyConfig));
  defaultNavSmoothing=abi.decode(_read(previous,abi.encodeWithSignature("defaultNavSmoothing()")),(NavSmoothingConfig));
  defaultLockPeriod=abi.decode(_read(previous,abi.encodeWithSignature("defaultLockPeriod()")),(uint64));
  defaultVaultDepositCap=abi.decode(_read(previous,abi.encodeWithSignature("defaultVaultDepositCap()")),(uint256));
  defaultUserDepositCap=abi.decode(_read(previous,abi.encodeWithSignature("defaultUserDepositCap()")),(uint256));
  defaultMinDepositAmount=abi.decode(_read(previous,abi.encodeWithSignature("defaultMinDepositAmount()")),(uint256));
  defaultMinRebalanceCooldown=abi.decode(_read(previous,abi.encodeWithSignature("defaultMinRebalanceCooldown()")),(uint256));
  defaultBatchGuardrails=abi.decode(_read(previous,abi.encodeWithSignature("defaultBatchGuardrails()")),(IParamsProvider.BatchGuardrails));
  defaultOracleConfig=abi.decode(_read(previous,abi.encodeWithSignature("defaultOracleConfig()")),(OracleConfig));
  defaultMinParamDelay=abi.decode(_read(previous,abi.encodeWithSignature("defaultMinParamDelay()")),(uint64));
  defaultMaxPerfRate=abi.decode(_read(previous,abi.encodeWithSignature("defaultMaxPerfRate()")),(uint256));
  defaultMaxFeeBps=abi.decode(_read(previous,abi.encodeWithSignature("defaultMaxFeeBps()")),(uint16));
  defaultMaxImmediateExitPenaltyBps=abi.decode(_read(previous,abi.encodeWithSignature("defaultMaxImmediateExitPenaltyBps()")),(uint16));
  defaultMaxForceExitPenaltyBps=abi.decode(_read(previous,abi.encodeWithSignature("defaultMaxForceExitPenaltyBps()")),(uint16));
  defaultGuardianPauseCooldown=abi.decode(_read(previous,abi.encodeWithSignature("defaultGuardianPauseCooldown()")),(uint64));
  defaultMinDeployAmount=abi.decode(_read(previous,abi.encodeWithSignature("defaultMinDeployAmount()")),(uint256));
  defaultStratTaGas=abi.decode(_read(previous,abi.encodeWithSignature("defaultStratTaGas()")),(uint256));
  defaultOpsMaxBps=abi.decode(_read(previous,abi.encodeWithSignature("defaultOpsMaxBps()")),(uint16));
  vaultFeeOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultFeeOverrides(address)",vault)),(FeeConfig));
  vaultWithdrawalOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultWithdrawalOverrides(address)",vault)),(WithdrawalConfig));
  vaultDynamicCapOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultDynamicCapOverrides(address)",vault)),(DynamicCapConfig));
  vaultQueueOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultQueueOverrides(address)",vault)),(QueueConfig));
  vaultSecurityOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultSecurityOverrides(address)",vault)),(SecurityConfig));
  vaultBufferOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultBufferOverrides(address)",vault)),(BufferConfig));
  vaultStrategyOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultStrategyOverrides(address)",vault)),(StrategyConfig));
  vaultNavSmoothingOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultNavSmoothingOverrides(address)",vault)),(NavSmoothingConfig));
  vaultLockOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultLockOverrides(address)",vault)),(uint64));
  vaultCapOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultCapOverrides(address)",vault)),(uint256));
  vaultUserCapOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultUserCapOverrides(address)",vault)),(uint256));
  vaultMinDepositOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMinDepositOverrides(address)",vault)),(uint256));
  vaultCooldownOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultCooldownOverrides(address)",vault)),(uint256));
  vaultBatchOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultBatchOverrides(address)",vault)),(IParamsProvider.BatchGuardrails));
  vaultOracleOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultOracleOverrides(address)",vault)),(OracleConfig));
  vaultMinParamDelayOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMinParamDelayOverrides(address)",vault)),(uint64));
  vaultMaxPerfRateOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMaxPerfRateOverrides(address)",vault)),(uint256));
  vaultMaxFeeBpsOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMaxFeeBpsOverrides(address)",vault)),(uint16));
  vaultMaxImmExitPenaltyOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMaxImmExitPenaltyOverrides(address)",vault)),(uint16));
  vaultMaxForceExitPenaltyOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMaxForceExitPenaltyOverrides(address)",vault)),(uint16));
  vaultGuardianPauseCooldownOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultGuardianPauseCooldownOverrides(address)",vault)),(uint64));
  vaultMinDeployAmountOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultMinDeployAmountOverrides(address)",vault)),(uint256));
  vaultStratTaGasOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultStratTaGasOverrides(address)",vault)),(uint256));
  vaultOpsMaxBpsOverrides[vault]=abi.decode(_read(previous,abi.encodeWithSignature("vaultOpsMaxBpsOverrides(address)",vault)),(uint16));
  assetOracleConfig[asset]=abi.decode(_read(previous,abi.encodeWithSignature("assetOracleConfig(address)",asset)),(OracleConfig));
  for(uint8 i;i<=uint8(ParamType.GOV_CAPS);i++) {
   hasOverride[vault][ParamType(i)]=abi.decode(_read(previous,abi.encodeWithSignature("hasOverride(address,uint8)",vault,i)),(bool));
  }
  // Old adapter-policy storage has no public raw getters. Inventory must show
  // no writes to those mappings. Fail closed for an active per-vault policy.
  require(!hasOverride[vault][ParamType.ADAPTER_POLICY],"adapter policy needs explicit migration");
  emit ConfigurationImported(previous,vault,asset);
 }
 function _read(address source,bytes memory data) private view returns(bytes memory result) {
  (bool ok,bytes memory ret)=source.staticcall(data);require(ok,"configuration read failed");return ret;
 }
}
