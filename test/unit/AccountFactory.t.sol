// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {AccountFactory} from "src/AccountFactory.sol";
import {SmartAccount} from "src/SmartAccount.sol";
import {TaskManager} from "src/TaskManager.sol";
import {ITaskManager} from "src/interface/ITaskManager.sol";

// Mock EntryPoint for testing
contract MockEntryPoint {
    // Minimal implementation for testing
}

contract AccountFactoryTest is Test {
    AccountFactory public factory;
    MockEntryPoint public mockEntryPoint;
    TaskManager public taskManager;
    
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    
    event CloneCreated(address indexed clone, address indexed user, bytes32 indexed salt);

    function setUp() public {
        mockEntryPoint = new MockEntryPoint();
        taskManager = new TaskManager();
        
        vm.prank(owner);
        factory = new AccountFactory(address(mockEntryPoint), owner, address(taskManager));
    }

    function testConstructor() public {
        assertEq(factory.s_owner(), owner);
        assertTrue(factory.implementation() != address(0));
        assertEq(address(factory.getEntryPoint()), address(mockEntryPoint));
        assertEq(address(factory.getTaskManager()), address(taskManager));
    }

    function testConstructorRevertsWithZeroEntryPoint() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidEntryPoint.selector);
        new AccountFactory(address(0), owner, address(taskManager));
    }

    function testConstructorRevertsWithZeroOwner() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidOwner.selector);
        new AccountFactory(address(mockEntryPoint), address(0), address(taskManager));
    }

    function testConstructorRevertsWithZeroTaskManager() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidTaskManager.selector);
        new AccountFactory(address(mockEntryPoint), owner, address(0));
    }

    function testCreateAccount() public {
        uint256 userNonce = 1;
        
        vm.startPrank(user1);
        
        bytes32 expectedSalt = keccak256(abi.encodePacked(user1, userNonce));
        address expectedAddress = factory.getAddress(userNonce);
        
        vm.expectEmit(true, true, true, true);
        emit CloneCreated(expectedAddress, user1, expectedSalt);
        
        address createdAccount = factory.createAccount(userNonce);
        
        assertEq(createdAccount, expectedAddress);
        assertEq(factory.getUserClone(user1), createdAccount);
        assertTrue(createdAccount.code.length > 0);
        
        // Verify the account is properly initialized
        SmartAccount smartAccount = SmartAccount(payable(createdAccount));
        assertEq(smartAccount.s_owner(), user1);
        assertEq(address(smartAccount.taskManager()), address(taskManager));
        
        vm.stopPrank();
    }

    function testCreateAccountRevertsIfAlreadyDeployed() public {
        uint256 userNonce = 1;
        
        vm.startPrank(user1);
        
        // Create account first time
        factory.createAccount(userNonce);
        
        // Try to create again with same nonce
        vm.expectRevert(AccountFactory.AccountFactory__ContractAlreadyDeployed.selector);
        factory.createAccount(userNonce);
        
        vm.stopPrank();
    }

    function testCreateAccountWithDifferentNonces() public {
        vm.startPrank(user1);
        
        address account1 = factory.createAccount(1);
        address account2 = factory.createAccount(2);
        
        assertTrue(account1 != account2);
        assertEq(factory.getUserClone(user1), account2); // Latest clone is stored
        
        vm.stopPrank();
    }

    function testCreateAccountForDifferentUsers() public {
        uint256 nonce = 1;
        
        vm.prank(user1);
        address account1 = factory.createAccount(nonce);
        
        vm.prank(user2);
        address account2 = factory.createAccount(nonce);
        
        assertTrue(account1 != account2);
        assertEq(factory.getUserClone(user1), account1);
        assertEq(factory.getUserClone(user2), account2);
    }

    function testGetAddress() public {
        uint256 userNonce = 1;
        
        vm.startPrank(user1);
        
        address predictedAddress = factory.getAddress(userNonce);
        address createdAddress = factory.createAccount(userNonce);
        
        assertEq(predictedAddress, createdAddress);
        
        vm.stopPrank();
    }

    function testGetAddressForUser() public {
        uint256 userNonce = 1;
        
        address predictedAddress = factory.getAddressForUser(user1, userNonce);
        
        vm.prank(user1);
        address createdAddress = factory.createAccount(userNonce);
        
        assertEq(predictedAddress, createdAddress);
    }

    function testGetUserClone() public {
        assertEq(factory.getUserClone(user1), address(0));
        
        vm.prank(user1);
        address account = factory.createAccount(1);
        
        assertEq(factory.getUserClone(user1), account);
    }

    function testGetImplementation() public {
        address implementation = factory.getImplementation();
        assertTrue(implementation != address(0));
        assertEq(implementation, factory.implementation());
    }

    function testPredictableAddresses() public {
        uint256 nonce1 = 1;
        uint256 nonce2 = 2;
        
        // Same user, different nonces should produce different addresses
        address predicted1 = factory.getAddressForUser(user1, nonce1);
        address predicted2 = factory.getAddressForUser(user1, nonce2);
        assertTrue(predicted1 != predicted2);
        
        // Different users, same nonce should produce different addresses
        address predictedUser1 = factory.getAddressForUser(user1, nonce1);
        address predictedUser2 = factory.getAddressForUser(user2, nonce1);
        assertTrue(predictedUser1 != predictedUser2);
        
        // Same parameters should always produce same address
        address predicted1Again = factory.getAddressForUser(user1, nonce1);
        assertEq(predicted1, predicted1Again);
    }

    function testFuzzCreateAccount(uint256 nonce, address user) public {
        vm.assume(user != address(0));
        vm.assume(nonce > 0);
        
        address predictedAddress = factory.getAddressForUser(user, nonce);
        
        vm.prank(user);
        address createdAddress = factory.createAccount(nonce);
        
        assertEq(predictedAddress, createdAddress);
        assertEq(factory.getUserClone(user), createdAddress);
        assertTrue(createdAddress.code.length > 0);
    }

    function testMultipleUsersMultipleNonces() public {
        address[] memory users = new address[](3);
        users[0] = makeAddr("testUser1");
        users[1] = makeAddr("testUser2");
        users[2] = makeAddr("testUser3");
        
        uint256[] memory nonces = new uint256[](3);
        nonces[0] = 1;
        nonces[1] = 42;
        nonces[2] = 999;
        
        for (uint256 i = 0; i < users.length; i++) {
            for (uint256 j = 0; j < nonces.length; j++) {
                vm.prank(users[i]);
                address account = factory.createAccount(nonces[j]);
                
                assertTrue(account != address(0));
                assertTrue(account.code.length > 0);
                
                SmartAccount smartAccount = SmartAccount(payable(account));
                assertEq(smartAccount.s_owner(), users[i]);
            }
        }
    }
}