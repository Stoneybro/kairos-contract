// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SimpleAccount} from "./SimpleAccount.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {TaskManager} from "./TaskManager.sol";

contract AccountFactory {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    address public immutable implementation;
    mapping(address user => address clone) public userClones;
    address private immutable i_entryPoint;
    address public immutable s_owner;
    
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CloneCreated(address indexed clone, address indexed user, bytes32 indexed salt);
    
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error AccountFactory__ContractAlreadyDeployed();
    error AccountFactory__InitializationFailed();

    /*CONSTRUCTOR*/
    constructor(address entryPoint, address owner) {
        if (entryPoint == address(0)) revert("Invalid entry point");
        if (owner == address(0)) revert("Invalid owner");
        
        implementation = address(new SimpleAccount());
        i_entryPoint = entryPoint;
        s_owner = owner;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createAccount(uint256 userNonce) external returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, userNonce));
        address predictedAddress = Clones.predictDeterministicAddress(implementation, salt);

        if (predictedAddress.code.length != 0) {
            revert AccountFactory__ContractAlreadyDeployed();
        }
        
        address account = Clones.cloneDeterministic(implementation, salt);
        userClones[msg.sender] = account;
        
        emit CloneCreated(account, msg.sender, salt);
        TaskManager taskManager = new TaskManager(account);
        try SimpleAccount(payable(account)).initialize(msg.sender, i_entryPoint,taskManager) {
            return account;
        } catch {
            revert AccountFactory__InitializationFailed();
        }
    }
    
    function getAddress(uint256 userNonce) external view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, userNonce));
        predictedAddress = Clones.predictDeterministicAddress(implementation, salt);
    }
    
    function getAddressForUser(address user, uint256 userNonce) external view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(user, userNonce));
        predictedAddress = Clones.predictDeterministicAddress(implementation, salt);
    }
    
    function getUserClone(address user) external view returns (address) {
        return userClones[user];
    }
}