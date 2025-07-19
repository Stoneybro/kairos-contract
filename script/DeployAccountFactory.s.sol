// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccountFactory} from "src/AccountFactory.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployAccountFactory is Script {
    function run() external returns (AccountFactory, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory networkConfig = helperConfig.getConfig();
        
        vm.startBroadcast();
        AccountFactory factory = new AccountFactory(networkConfig.entryPoint, msg.sender);
        vm.stopBroadcast();
        
        console.log("AccountFactory deployed at:", address(factory));
        console.log("EntryPoint used:", networkConfig.entryPoint);
        console.log("Factory owner:", msg.sender);
        
        return (factory, helperConfig);
    }
    
    function deployFactory(address entryPoint, address owner) external returns (AccountFactory) {
        vm.startBroadcast();
        AccountFactory factory = new AccountFactory(entryPoint, owner);
        vm.stopBroadcast();
        
        return factory;
    }
}