// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {StrategyRouter} from "../../../src/core/modules/StrategyRouter.sol";
import {IStrategyRouter} from "../../../src/interfaces/IStrategyRouter.sol";
contract RegressionCore {function asset() external pure returns(address){return address(1);} function grossAssets() external pure returns(uint){return 100e6;}}
contract RegressionLeg {
 bool public paused; bool public depositsDisabled; uint public totalAssets;
 function asset() external pure returns(address){return address(1);}
 function set(bool p,bool d,uint a) external {paused=p;depositsDisabled=d;totalAssets=a;}
}
contract RegressionScorer {function computeAllocations(address[] calldata legs,uint amount) external pure returns(uint[] memory a){a=new uint[](legs.length);for(uint i;i<a.length;i++)a[i]=amount/4;}}
contract StrategyRouter_MultiStrategyRegression is Test {
 function stratTaGas(address) external pure returns(uint){return 1000000;}
 StrategyRouter r; RegressionLeg a; RegressionLeg b;
 function setUp() public {r=new StrategyRouter(address(this),address(new RegressionCore()),address(this));a=new RegressionLeg();b=new RegressionLeg();uint eta=r.proposeStrategyAllowlist(address(a));r.proposeStrategyAllowlist(address(b));vm.warp(eta);r.executeStrategyAllowlist(address(a));r.executeStrategyAllowlist(address(b));r.register(address(a),0,5000);r.register(address(b),1,5000);r.setIntakeMode(IStrategyRouter.IntakeMode.WEIGHTED);}
 function test_pausedAndDepositDisabledFailClosed() public {a.set(true,false,0);assertEq(r.depositCapacity(address(a),100e6),0);a.set(false,true,0);assertEq(r.depositCapacity(address(a),100e6),0);}
 function test_missingIntakeMetadataFailsClosed() public {vm.mockCallRevert(address(a),abi.encodeWithSignature("paused()"),bytes("missing"));assertEq(r.depositCapacity(address(a),100e6),0);}
 function test_disabledWeightedLegRenormalizes() public {r.toggle(address(a),false);IStrategyRouter.Allocation[] memory p=r.planDeposit(1e6);assertEq(p.length,1);assertEq(p[0].strat,address(b));assertEq(p[0].amount,1e6);}
 function test_disabledAssetsStillCount() public {a.set(false,false,7e6);r.toggle(address(a),false);assertEq(r.totalStrategyAssetsSafe(),7e6);}
 function test_capHeadroomAndResidual() public {r.setMaxStrategyBps(address(a),100);a.set(false,false,900000);IStrategyRouter.Allocation[] memory p=r.planDeposit(2e6);assertEq(p[0].amount,100000);assertEq(p[1].amount,1e6);a.set(false,false,1000000);assertEq(r.depositCapacity(address(a),100e6),0);}
 function test_scoredCannotActivateWithoutScorer() public {vm.expectRevert(bytes4(keccak256("InvalidScorer()")));r.setIntakeMode(IStrategyRouter.IntakeMode.SCORED);}
 function test_scoredShortfallNotRedistributed() public {r.setScorer(address(new RegressionScorer()));r.setIntakeMode(IStrategyRouter.IntakeMode.SCORED);IStrategyRouter.Allocation[] memory p=r.planDeposit(1e6);assertEq(p[0].amount,250000);assertEq(p[1].amount,250000);vm.expectRevert(bytes4(keccak256("InvalidScorer()")));r.setScorer(address(0));}
}
