// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {AccountFactory} from "../../src/AccountFactory.sol";
import {SmartAccount} from "../../src/SmartAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ITaskManager} from "../../src/interface/ITaskManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title AccountFactoryTest
 * @author Test Suite
 * @notice Comprehensive test suite for AccountFactory contract
 * @dev Tests all functionality including constructor, account creation, address prediction, and error conditions
 */
contract AccountFactoryTest is Test {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    AccountFactory public accountFactory;
    MockEntryPoint public mockEntryPoint;
    MockTaskManager public mockTaskManager;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CloneCreated(address indexed clone, address indexed user, bytes32 indexed salt);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Deploy mock contracts
        mockEntryPoint = new MockEntryPoint();
        mockTaskManager = new MockTaskManager();

        // Deploy AccountFactory
        accountFactory = new AccountFactory(address(mockEntryPoint), address(mockTaskManager));
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_Success() public view {
        // Verify implementation is deployed
        address implementation = accountFactory.getImplementation();
        assertTrue(implementation != address(0));

        // Verify EntryPoint is set correctly
        assertEq(accountFactory.getEntryPoint(), address(mockEntryPoint));

        // Verify TaskManager is set correctly
        assertEq(accountFactory.getTaskManager(), address(mockTaskManager));

        // Verify implementation is a SmartAccount
        SmartAccount smartAccount = SmartAccount(payable(implementation));
        // Should not be initialized (constructor disables initializers)
        // The implementation contract should not have an owner set
        assertEq(smartAccount.s_owner(), address(0));
    }

    function test_Constructor_InvalidEntryPoint() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidEntryPoint.selector);
        new AccountFactory(address(0), address(mockTaskManager));
    }

    function test_Constructor_InvalidTaskManager() public {
        vm.expectRevert(AccountFactory.AccountFactory__InvalidTaskManager.selector);
        new AccountFactory(address(mockEntryPoint), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE ACCOUNT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateAccount_Success() public {
        vm.prank(alice);
        address account = accountFactory.createAccount(alice);

        // Verify account is deployed
        assertTrue(account != address(0));
        assertTrue(account.code.length > 0);

        // Verify account is initialized correctly
        SmartAccount smartAccount = SmartAccount(payable(account));
        assertEq(smartAccount.s_owner(), alice);
        assertEq(address(smartAccount.i_entryPoint()), address(mockEntryPoint));
        assertEq(address(smartAccount.taskManager()), address(mockTaskManager));

        // Verify mapping is updated
        assertEq(accountFactory.getUserClone(alice), account);

        // Verify deterministic address
        address predicted = accountFactory.getAddressForUser(alice);
        assertEq(account, predicted);
    }

    function test_CreateAccount_EventEmitted() public {
        vm.expectEmit(true, true, true, true);
        bytes32 salt = keccak256(abi.encodePacked(alice));
        address predicted = accountFactory.getAddressForUser(alice);
        emit CloneCreated(predicted, alice, salt);

        vm.prank(alice);
        accountFactory.createAccount(alice);
    }

    function test_CreateAccount_UserAlreadyHasAccount() public {
        // First creation should succeed
        vm.prank(alice);
        address firstAccount = accountFactory.createAccount(alice);
        assertTrue(firstAccount != address(0));

        // Second creation should fail
        vm.prank(alice);
        vm.expectRevert(AccountFactory.AccountFactory__UserAlreadyHasAccount.selector);
        accountFactory.createAccount(alice);
    }

    function test_CreateAccount_DifferentUsers() public {
        // Alice creates account
        vm.prank(alice);
        address aliceAccount = accountFactory.createAccount(alice);

        // Bob creates account
        vm.prank(bob);
        address bobAccount = accountFactory.createAccount(bob);

        // Charlie creates account
        vm.prank(charlie);
        address charlieAccount = accountFactory.createAccount(charlie);

        // All accounts should be different
        assertTrue(aliceAccount != bobAccount);
        assertTrue(bobAccount != charlieAccount);
        assertTrue(aliceAccount != charlieAccount);

        // All accounts should be valid
        assertTrue(aliceAccount != address(0));
        assertTrue(bobAccount != address(0));
        assertTrue(charlieAccount != address(0));

        // Verify mappings
        assertEq(accountFactory.getUserClone(alice), aliceAccount);
        assertEq(accountFactory.getUserClone(bob), bobAccount);
        assertEq(accountFactory.getUserClone(charlie), charlieAccount);
    }

    function test_CreateAccount_DeterministicAddresses() public {
        // Predict addresses before creation
        address alicePredicted = accountFactory.getAddressForUser(alice);
        address bobPredicted = accountFactory.getAddressForUser(bob);

        // Create accounts
        vm.prank(alice);
        address aliceAccount = accountFactory.createAccount(alice);

        vm.prank(bob);
        address bobAccount = accountFactory.createAccount(bob);

        // Verify addresses match predictions
        assertEq(aliceAccount, alicePredicted);
        assertEq(bobAccount, bobPredicted);
    }

    function test_CreateAccount_AccountAlreadyDeployed() public {
        // First, create account normally
        vm.prank(alice);
        accountFactory.createAccount(alice);

        // Try to create another account for the same user
        vm.prank(alice);
        vm.expectRevert(AccountFactory.AccountFactory__UserAlreadyHasAccount.selector);
        accountFactory.createAccount(alice);
    }

    /*//////////////////////////////////////////////////////////////
                        ADDRESS PREDICTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetAddressForUser_Consistent() public view {
        address predicted1 = accountFactory.getAddressForUser(alice);
        address predicted2 = accountFactory.getAddressForUser(alice);

        // Should be consistent
        assertEq(predicted1, predicted2);
    }

    function test_GetAddressForUser_DifferentUsers() public view {
        address alicePredicted = accountFactory.getAddressForUser(alice);
        address bobPredicted = accountFactory.getAddressForUser(bob);

        // Should be different
        assertTrue(alicePredicted != bobPredicted);
    }

    function test_GetAddressForUser_MatchesActualDeployment() public {
        address predicted = accountFactory.getAddressForUser(alice);

        vm.prank(alice);
        address actual = accountFactory.createAccount(alice);

        assertEq(predicted, actual);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUserClone_NoAccount() public view {
        address clone = accountFactory.getUserClone(alice);
        assertEq(clone, address(0));
    }

    function test_GetUserClone_WithAccount() public {
        vm.prank(alice);
        address account = accountFactory.createAccount(alice);

        address clone = accountFactory.getUserClone(alice);
        assertEq(clone, account);
    }

    function test_GetImplementation() public view {
        address implementation = accountFactory.getImplementation();
        assertTrue(implementation != address(0));

        // Should be a SmartAccount
        SmartAccount smartAccount = SmartAccount(payable(implementation));
        // Constructor should disable initializers, so owner should be zero
        assertEq(smartAccount.s_owner(), address(0));
    }

    function test_GetEntryPoint() public view {
        address entryPoint = accountFactory.getEntryPoint();
        assertEq(entryPoint, address(mockEntryPoint));
    }

    function test_GetTaskManager() public view {
        address taskManager = accountFactory.getTaskManager();
        assertEq(taskManager, address(mockTaskManager));
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_CreateAccount_ZeroAddress() public {
        vm.prank(address(0));
        address account = accountFactory.createAccount(address(0));

        // Zero address should still create an account (salt will be keccak256(abi.encodePacked(address(0))))
        assertTrue(account != address(0));
        assertEq(accountFactory.getUserClone(address(0)), account);
    }

    function test_CreateAccount_ContractAddress() public {
        // Deploy a simple contract
        MockContract mockContract = new MockContract();

        vm.prank(address(mockContract));
        address account = accountFactory.createAccount(address(mockContract));

        assertTrue(account != address(0));
        assertEq(accountFactory.getUserClone(address(mockContract)), account);
    }

    function test_CreateAccount_MultipleCallsSameTx() public {
        vm.startPrank(alice);

        // First call should succeed
        address account1 = accountFactory.createAccount(alice);
        assertTrue(account1 != address(0));

        // Second call should fail
        vm.expectRevert(AccountFactory.AccountFactory__UserAlreadyHasAccount.selector);
        accountFactory.createAccount(alice);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            GAS OPTIMIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateAccount_GasUsage() public {
        uint256 gasStart = gasleft();

        vm.prank(alice);
        accountFactory.createAccount(alice);

        uint256 gasUsed = gasStart - gasleft();

        // Log gas usage for optimization reference
        console.log("Gas used for createAccount:", gasUsed);

        // Should be reasonable (adjust threshold as needed)
        assertTrue(gasUsed < 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_SmartAccountFunctionality() public {
        // Create account
        vm.prank(alice);
        address account = accountFactory.createAccount(alice);

        SmartAccount smartAccount = SmartAccount(payable(account));

        // Verify account can receive ETH
        vm.deal(account, 1 ether);
        assertEq(account.balance, 1 ether);

        // Verify account properties
        assertEq(smartAccount.s_owner(), alice);
        assertEq(address(smartAccount.i_entryPoint()), address(mockEntryPoint));
        assertEq(address(smartAccount.taskManager()), address(mockTaskManager));

        // Verify available balance calculation
        uint256 availableBalance = smartAccount.getAvailableBalance();
        assertEq(availableBalance, 1 ether);
    }

    function test_Integration_MultipleAccounts() public {
        address[] memory accounts = new address[](3);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        // Create multiple accounts
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            accounts[i] = accountFactory.createAccount(users[i]);

            // Verify each account
            assertTrue(accounts[i] != address(0));
            assertEq(accountFactory.getUserClone(users[i]), accounts[i]);

            // Fund each account
            vm.deal(accounts[i], 1 ether);
        }

        // Verify all accounts are unique
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = i + 1; j < accounts.length; j++) {
                assertTrue(accounts[i] != accounts[j]);
            }
        }
    }
}

/*//////////////////////////////////////////////////////////////
                            MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/**
 * @title MockEntryPoint
 * @notice Mock implementation of IEntryPoint for testing
 */
contract MockEntryPoint {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {
        // Mock implementation
    }

    function getDeposit(address account) external view returns (uint256) {
        return deposits[account];
    }

    function balanceOf(address account) external view returns (uint256) {
        return deposits[account];
    }
}

/**
 * @title MockTaskManager
 * @notice Mock implementation of ITaskManager for testing
 */
contract MockTaskManager is ITaskManager {
    mapping(address => mapping(uint256 => Task)) public tasks;
    mapping(address => uint256) public taskCounts;

    function createTask(
        string calldata title,
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external override returns (uint256) {
        uint256 taskId = taskCounts[msg.sender]++;

        tasks[msg.sender][taskId] = Task({
            id: taskId,
            title: title,
            description: description,
            rewardAmount: rewardAmount,
            deadline: deadlineInSeconds,
            valid: true,
            status: TaskStatus.ACTIVE,
            choice: choice,
            delayDuration: delayDuration,
            buddy: buddy,
            delayedRewardReleased: false,
            buddyPaymentSent: false,
            verificationMethod: VerificationMethod(verificationMethod)
        });

        return taskId;
    }

    function completeTask(uint256 taskId) external override {
        tasks[msg.sender][taskId].status = TaskStatus.COMPLETED;
    }

    function cancelTask(uint256 taskId) external override {
        tasks[msg.sender][taskId].status = TaskStatus.CANCELED;
    }

    function releaseDelayedPayment(uint256 taskId) external override {
        tasks[msg.sender][taskId].delayedRewardReleased = true;
    }

    function releaseBuddyPayment(uint256 taskId) external override {
        tasks[msg.sender][taskId].buddyPaymentSent = true;
    }

    function getTask(address account, uint256 taskId) external view override returns (Task memory) {
        return tasks[account][taskId];
    }

    function getTasksByStatus(address, TaskStatus, uint256, uint256) external pure override returns (Task[] memory) {
        // Mock implementation
        Task[] memory result = new Task[](0);
        return result;
    }

    function getTaskCountsByStatus(address) external pure override returns (uint256[] memory) {
        // Mock implementation
        uint256[] memory result = new uint256[](4);
        return result;
    }

    function getTotalTasks(address account) external view override returns (uint256) {
        return taskCounts[account];
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITaskManager).interfaceId;
    }
}

/**
 * @title MockContract
 * @notice Simple contract for testing contract address scenarios
 */
contract MockContract {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}
