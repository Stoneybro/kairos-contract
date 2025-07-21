// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SmartAccount} from "./SmartAccount.sol";
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
    error  AccountFactory__InvalidEntryPoint();
    error AccountFactory__InvalidOwner();
    /*CONSTRUCTOR*/
    constructor(address entryPoint, address owner) {
        if (entryPoint == address(0)) revert AccountFactory__InvalidEntryPoint();
        if (owner == address(0)) revert AccountFactory__InvalidOwner();
        implementation = address(new SmartAccount());
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
        try SmartAccount(payable(account)).initialize(msg.sender, i_entryPoint,taskManager) {
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