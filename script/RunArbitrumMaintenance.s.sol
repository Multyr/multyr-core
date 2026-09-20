// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface MaintenanceVm {
    function envOr(string calldata, address) external returns (address);
    function envOr(string calldata, uint256) external returns (uint256);
    function addr(uint256) external returns (address);
    function startBroadcast(uint256) external;
    function startBroadcast(address) external;
    function stopBroadcast() external;
}
interface CheckedUpkeep {
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory);
    function performUpkeep(bytes calldata) external;
}
interface MaintenanceView {
    function idleCash() external view returns (uint256);
    function positions() external view returns (address[] memory,uint256[] memory);
}
interface AdapterAssets { function totalAssets() external view returns(uint256); }

/// @notice Runs contract-selected maintenance only; never changes roles, caps or allocations.
/// @dev Forge consumes .env locally. Never pass a private key on a command line.
contract RunArbitrumMaintenance {
    MaintenanceVm constant vm=MaintenanceVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant EXPECTED=0x908756f36954f2853134259B8846c49F90E84ECe;
    address constant CORE=0x8672921E03c9995AE1Dbe234A7a08C327163883e;
    address constant UPKEEP=0xd32a464df8e90D8aa9Bc290C4635eCE8D5362550;
    address constant STRATEGY=0x2ca30120C828Fc136d348234f7e68116572DD83E;
    event MaintenanceCall(address indexed upkeep,uint256 operation,bytes performData);
    event PositionSnapshot(bool afterRun,address indexed adapter,uint256 recordedAssets,uint256 reportedAssets,bool reportedOk);
    event IdleSnapshot(bool afterRun,uint256 assets);
    event NoWork(address indexed upkeep);
    event RepeatedActionStopped(address indexed upkeep,uint256 operation);

    function run() external {
        require(block.chainid==42161,"Arbitrum One required");
        require(CORE.code.length>0 && UPKEEP.code.length>0 && STRATEGY.code.length>0,"missing deployment");
        address sender=vm.envOr("DEPLOYER_ADDRESS",EXPECTED);
        require(sender==EXPECTED,"unexpected deployer; review sender");
        uint256 steps=vm.envOr("MAINTENANCE_MAX_STEPS",uint256(4));
        require(steps>0 && steps<=8,"steps must be 1..8");
        _snapshot(false);
        // A key remains opaque to the agent: only Forge consumes it. With no key,
        // use an explicitly selected Foundry account matching DEPLOYER_ADDRESS.
        uint256 key=vm.envOr("DEPLOYER_PRIVATE_KEY",uint256(0));
        if(key!=0) { require(vm.addr(key)==sender,"key/sender mismatch"); vm.startBroadcast(key); }
        else vm.startBroadcast(sender);
        _once(CORE);
        bytes32 previous;
        for(uint256 i;i<steps;i++) {
            (bool needed,bytes memory data)=CheckedUpkeep(UPKEEP).checkUpkeep("");
            if(!needed) {emit NoWork(UPKEEP);break;}
            uint256 op=_op(data);
            bytes32 fingerprint=keccak256(data);
            // Multi-step rebalance legitimately repeats its opcode. Other repeated
            // actions may reflect a swallowed failure: stop instead of burning gas.
            if(i>0 && fingerprint==previous && op!=6) {emit RepeatedActionStopped(UPKEEP,op);break;}
            previous=fingerprint;
            emit MaintenanceCall(UPKEEP,op,data);
            CheckedUpkeep(UPKEEP).performUpkeep(data);
        }
        vm.stopBroadcast();
        _snapshot(true);
    }
    function _once(address target) internal {
        (bool needed,bytes memory data)=CheckedUpkeep(target).checkUpkeep("");
        if(!needed) {emit NoWork(target);return;}
        emit MaintenanceCall(target,_op(data),data);
        CheckedUpkeep(target).performUpkeep(data);
    }
    function _op(bytes memory data) internal pure returns(uint256 op) {
        if(data.length==1)return uint8(data[0]);
        require(data.length>=64,"bad upkeep response");
        (op,)=abi.decode(data,(uint256,uint256));
    }
    function _snapshot(bool afterRun) internal {
        emit IdleSnapshot(afterRun,MaintenanceView(STRATEGY).idleCash());
        (address[] memory adapters,uint256[] memory amounts)=MaintenanceView(STRATEGY).positions();
        for(uint256 i;i<adapters.length;i++) {
            try AdapterAssets(adapters[i]).totalAssets() returns(uint256 assets) {
                emit PositionSnapshot(afterRun,adapters[i],amounts[i],assets,true);
            } catch {emit PositionSnapshot(afterRun,adapters[i],amounts[i],0,false);}
        }
    }
}
