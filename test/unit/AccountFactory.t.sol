// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {AccountFactory} from "src/AccountFactory.sol";
import {SmartAccount} from "src/SmartAccount.sol";
import {TaskManager} from "src/TaskManager.sol";

// Mock EntryPoint for testing
contract MockEntryPoint {
// Simple mock that accepts calls
}

contract AccountFactoryTest is Test {
    AccountFactory public accountFactory;
    MockEntryPoint public entryPoint;

    address public owner;
    address public user1;
    address public user2;
    address public invalidAddress;

    uint256 constant USER_NONCE_1 = 123;
    uint256 constant USER_NONCE_2 = 456;

    event CloneCreated(address indexed clone, address indexed user, bytes32 indexed salt);

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        invalidAddress = address(0);

        entryPoint = new MockEntryPoint();
        accountFactory = new AccountFactory(address(entryPoint), owner);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testConstructorSetsCorrectValues() public view {
        assertEq(accountFactory.s_owner(), owner);
        assertNotEq(accountFactory.implementation(), address(0));
    }

    function testConstructorRevertsWithInvalidEntryPoint() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidEntryPoint.selector);
        new AccountFactory(address(0), owner);
    }

    function testConstructorRevertsWithInvalidOwner() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidOwner.selector);
        new AccountFactory(address(entryPoint), address(0));
    }

    function testConstructorCreatesImplementation() public view {
        address impl = accountFactory.implementation();
        assertTrue(impl != address(0));
        assertTrue(impl.code.length > 0);
    }

    /*//////////////////////////////////////////////////////////////
                           ACCOUNT CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateAccount() public {
        bytes32 expectedSalt = keccak256(abi.encodePacked(user1, USER_NONCE_1));
        vm.prank(user1);
        address predictedAccount = accountFactory.getAddress(USER_NONCE_1);
        vm.prank(user1);
        vm.expectEmit(true, true, true, false);
        emit CloneCreated(predictedAccount, user1, expectedSalt); // Address will be different, so we use address(0)
        address account = accountFactory.createAccount(USER_NONCE_1);

        // Verify account was created
        assertTrue(account == predictedAccount);
        assertTrue(account != address(0));
        assertTrue(account.code.length > 0);

        // Verify mapping was updated
        assertEq(accountFactory.getUserClone(user1), account);

        // Verify account was initialized correctly
        SmartAccount smartAccount = SmartAccount(payable(account));
        assertEq(smartAccount.s_owner(), user1);

        // Verify task manager was deployed and linked
        address taskManagerAddr = smartAccount.getTaskManagerAddress();
        assertTrue(taskManagerAddr != address(0));

        TaskManager taskManager = TaskManager(taskManagerAddr);
        assertEq(taskManager.owner(), account);
    }

    function testCreateAccountForDifferentUsers() public {
        // Create account for user1
        vm.prank(user1);
        address account1 = accountFactory.createAccount(USER_NONCE_1);

        // Create account for user2
        vm.prank(user2);
        address account2 = accountFactory.createAccount(USER_NONCE_1);

        // Accounts should be different
        assertTrue(account1 != account2);

        // Verify mappings
        assertEq(accountFactory.getUserClone(user1), account1);
        assertEq(accountFactory.getUserClone(user2), account2);

        // Verify owners
        SmartAccount smartAccount1 = SmartAccount(payable(account1));
        SmartAccount smartAccount2 = SmartAccount(payable(account2));

        assertEq(smartAccount1.s_owner(), user1);
        assertEq(smartAccount2.s_owner(), user2);
    }

    function testCreateAccountWithDifferentNonces() public {
        vm.startPrank(user1);

        // Create first account with nonce 1
        address account1 = accountFactory.createAccount(USER_NONCE_1);

        // Create second account with nonce 2
        address account2 = accountFactory.createAccount(USER_NONCE_2);

        vm.stopPrank();

        // Accounts should be different
        assertTrue(account1 != account2);

        // Both should have same owner but different addresses
        SmartAccount smartAccount1 = SmartAccount(payable(account1));
        SmartAccount smartAccount2 = SmartAccount(payable(account2));

        assertEq(smartAccount1.s_owner(), user1);
        assertEq(smartAccount2.s_owner(), user1);

        // Note: getUserClone will only return the last created account
        // This is a limitation of the current implementation
        assertEq(accountFactory.getUserClone(user1), account2);
    }

    function testCreateAccountRevertsIfAlreadyDeployed() public {
        vm.startPrank(user1);

        // Create first account
        accountFactory.createAccount(USER_NONCE_1);

        // Try to create with same nonce - should revert
        vm.expectRevert(AccountFactory.AccountFactory__ContractAlreadyDeployed.selector);
        accountFactory.createAccount(USER_NONCE_1);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         ADDRESS PREDICTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetAddress() public {
        vm.prank(user1);

        // Get predicted address
        address predictedAddress = accountFactory.getAddress(USER_NONCE_1);

        vm.prank(user1);
        // Create actual account
        address actualAddress = accountFactory.createAccount(USER_NONCE_1);

        // They should match
        assertEq(predictedAddress, actualAddress);
    }

    function testGetAddressForUser() public {
        // Get predicted address for user1
        address predictedAddress = accountFactory.getAddressForUser(user1, USER_NONCE_1);

        // Create actual account
        vm.prank(user1);
        address actualAddress = accountFactory.createAccount(USER_NONCE_1);

        // They should match
        assertEq(predictedAddress, actualAddress);
    }

    function testGetAddressConsistency() public view {
        // Multiple calls should return same address
        address addr1 = accountFactory.getAddressForUser(user1, USER_NONCE_1);
        address addr2 = accountFactory.getAddressForUser(user1, USER_NONCE_1);

        assertEq(addr1, addr2);
    }

    function testGetAddressDifferentForDifferentInputs() public view {
        // Different users, same nonce
        address addr1 = accountFactory.getAddressForUser(user1, USER_NONCE_1);
        address addr2 = accountFactory.getAddressForUser(user2, USER_NONCE_1);
        assertTrue(addr1 != addr2);

        // Same user, different nonces
        address addr3 = accountFactory.getAddressForUser(user1, USER_NONCE_1);
        address addr4 = accountFactory.getAddressForUser(user1, USER_NONCE_2);
        assertTrue(addr3 != addr4);
    }

    /*//////////////////////////////////////////////////////////////
                            USER CLONE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUserClone() public {
        // Initially should return zero address
        assertEq(accountFactory.getUserClone(user1), address(0));

        // Create account
        vm.prank(user1);
        address account = accountFactory.createAccount(USER_NONCE_1);

        // Should now return the created account
        assertEq(accountFactory.getUserClone(user1), account);
    }

    function testGetUserCloneForNonExistentUser() public view {
        assertEq(accountFactory.getUserClone(user1), address(0));
    }

    function testGetUserCloneUpdatesWithNewAccount() public {
        vm.startPrank(user1);

        // Create first account
        address account1 = accountFactory.createAccount(USER_NONCE_1);
        assertEq(accountFactory.getUserClone(user1), account1);

        // Create second account (different nonce)
        address account2 = accountFactory.createAccount(USER_NONCE_2);
        assertEq(accountFactory.getUserClone(user1), account2);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteAccountCreationFlow() public {
        vm.prank(user1);

        // 1. Predict address
        address predictedAddress = accountFactory.getAddress(USER_NONCE_1);

        vm.prank(user1);
        // 2. Create account
        address actualAddress = accountFactory.createAccount(USER_NONCE_1);

        // 3. Verify prediction was correct
        assertEq(predictedAddress, actualAddress);

        // 4. Verify account is properly initialized
        SmartAccount account = SmartAccount(payable(actualAddress));
        assertEq(account.s_owner(), user1);

        // 5. Verify task manager is deployed and linked
        address taskManagerAddr = account.getTaskManagerAddress();
        assertTrue(taskManagerAddr != address(0));

        TaskManager taskManager = TaskManager(taskManagerAddr);
        assertEq(taskManager.owner(), actualAddress);

        // 6. Verify factory mapping
        assertEq(accountFactory.getUserClone(user1), actualAddress);
    }

    function testAccountFunctionalityAfterCreation() public {
        vm.prank(user1);
        address accountAddr = accountFactory.createAccount(USER_NONCE_1);

        SmartAccount account = SmartAccount(payable(accountAddr));

        // Fund the account
        vm.deal(accountAddr, 10 ether);

        // Test task creation (basic functionality test)
        vm.prank(user1);
        account.createTask(
            "Test task",
            1 ether,
            3600, // 1 hour
            1, // delayed payment
            user2,
            86400 // 1 day delay
        );

        // Verify task was created
        assertEq(account.getTotalTasks(), 1);

        TaskManager.Task memory task = account.getTask(0);
        assertEq(task.description, "Test task");
        assertEq(task.rewardAmount, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzzCreateAccountWithDifferentNonces(uint256 nonce) public {
        // Bound nonce to reasonable range to avoid gas issues
        nonce = bound(nonce, 0, type(uint128).max);

        vm.prank(user1);
        address account = accountFactory.createAccount(nonce);

        assertTrue(account != address(0));
        assertEq(accountFactory.getUserClone(user1), account);

        SmartAccount smartAccount = SmartAccount(payable(account));
        assertEq(smartAccount.s_owner(), user1);
    }

    function testFuzzAddressPrediction(address user, uint256 nonce) public {
        // Skip zero address and precompiled addresses
        vm.assume(user != address(0) && uint160(user) > 10);
        nonce = bound(nonce, 0, type(uint128).max);

        // Get predicted address
        address predicted = accountFactory.getAddressForUser(user, nonce);

        // Create actual account
        vm.prank(user);
        address actual = accountFactory.createAccount(nonce);

        assertEq(predicted, actual);
    }

    /*//////////////////////////////////////////////////////////////
                            ERROR TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateAccountWithPrecomputedAddress() public {
        vm.prank(user1);
        address predictedAddr = accountFactory.getAddress(USER_NONCE_1);
        vm.prank(user1);
        address actualAddr = accountFactory.createAccount(USER_NONCE_1);
        assertEq(predictedAddr, actualAddr);
        vm.prank(user1);
        vm.expectRevert(AccountFactory.AccountFactory__ContractAlreadyDeployed.selector);
        accountFactory.createAccount(USER_NONCE_1);
    }

    /*//////////////////////////////////////////////////////////////
                           MULTIPLE USER TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultipleUsersCreateAccounts() public {
        address[] memory users = new address[](5);
        address[] memory accounts = new address[](5);

        // Create multiple users
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));

            vm.prank(users[i]);
            accounts[i] = accountFactory.createAccount(USER_NONCE_1);

            // Verify each account
            assertTrue(accounts[i] != address(0));
            assertEq(accountFactory.getUserClone(users[i]), accounts[i]);

            SmartAccount account = SmartAccount(payable(accounts[i]));
            assertEq(account.s_owner(), users[i]);
        }

        // Verify all accounts are different
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                assertTrue(accounts[i] != accounts[j]);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function testCreateAccountWithMaxNonce() public {
        vm.prank(user1);

        uint256 maxNonce = type(uint256).max;
        address account = accountFactory.createAccount(maxNonce);

        assertTrue(account != address(0));
        assertEq(accountFactory.getUserClone(user1), account);
    }

    function testCreateAccountWithZeroNonce() public {
        vm.prank(user1);

        address account = accountFactory.createAccount(0);

        assertTrue(account != address(0));
        assertEq(accountFactory.getUserClone(user1), account);
    }

    function testGetAddressConsistentAcrossBlocks() public {
        // Get address in current block
        address addr1 = accountFactory.getAddressForUser(user1, USER_NONCE_1);

        // Move to next block
        vm.roll(block.number + 1);

        // Address should be the same
        address addr2 = accountFactory.getAddressForUser(user1, USER_NONCE_1);
        assertEq(addr1, addr2);
    }

    /*//////////////////////////////////////////////////////////////
                           REAL WORLD SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function testBatchAccountCreation() public {
        uint256 numAccounts = 10;
        address[] memory users = new address[](numAccounts);
        address[] memory accounts = new address[](numAccounts);

        // Batch create accounts
        for (uint256 i = 0; i < numAccounts; i++) {
            users[i] = address(uint160(1000 + i)); // Generate test addresses

            vm.prank(users[i]);
            accounts[i] = accountFactory.createAccount(i);
        }

        // Verify all accounts were created successfully
        for (uint256 i = 0; i < numAccounts; i++) {
            assertTrue(accounts[i] != address(0));
            assertEq(accountFactory.getUserClone(users[i]), accounts[i]);
        }
    }

    function testFactoryStateAfterMultipleOperations() public {
        // Perform various operations
        vm.prank(user1);
        address account1 = accountFactory.createAccount(USER_NONCE_1);

        vm.prank(user2);
        address account2 = accountFactory.createAccount(USER_NONCE_2);

        // Verify factory state is consistent
        assertEq(accountFactory.getUserClone(user1), account1);
        assertEq(accountFactory.getUserClone(user2), account2);
        assertEq(accountFactory.s_owner(), owner);

        // Implementation should remain unchanged
        assertTrue(accountFactory.implementation() != address(0));
    }
}
