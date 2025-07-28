// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {TaskManager} from "../src/TaskManager.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployTaskManager is Script{
    function run() external returns (TaskManager ) {
        vm.startBroadcast();
        TaskManager taskManager = new TaskManager();
        vm.stopBroadcast();
        return taskManager;
    
    }

}