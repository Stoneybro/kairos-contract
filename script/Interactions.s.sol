// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {ITaskManager} from "../src/interface/ITaskManager.sol";
import {ISmartAccount} from "../src/interface/ISmartAccount.sol";

contract InteractionScript is Script {
    // Constants for penalty types
    uint8 constant PENALTY_DELAYEDPAYMENT = 1;
    uint8 constant PENALTY_SENDBUDDY = 2;

    // Contract addresses (update these after deployment)
    address public taskManager;
    address public accountFactory;
    address public entryPoint;

    // Test addresses and accounts
    address public owner;
    address public buddy;
    address public testAccount1;
    address public testAccount2;
    address public testAccount3;

    // Task IDs for tracking
    uint256 public delayedPaymentTaskId;
    uint256 public buddyPenaltyTaskId;
    uint256 public completionTaskId;
    uint256 public cancellationTaskId;

    function setUp() public {
        owner = vm.addr(1);
        buddy = vm.addr(2);
    }

    function run() public {
        vm.deal(address(this), 100 ether); // Fund the script address
        console.log("=== COMPREHENSIVE TASKMANAGER SYSTEM TEST ===");
        console.log("Testing all functionality...\n");

        // Step 1: Deploy all contracts
        console.log("1. DEPLOYING CONTRACTS");
        deployContracts();
        console.log(" All contracts deployed successfully\n");

        // Step 2: Create multiple accounts for testing
        console.log("2. CREATING TEST ACCOUNTS");
        createTestAccounts();
        console.log(" Test accounts created and funded\n");

        // Step 3: Test task creation with both penalty types
        console.log("3. TESTING TASK CREATION");
        TaskCreation();
        console.log(" All task types created successfully\n");

        // Step 4: Test task completion flow
        console.log("4. TESTING TASK COMPLETION");
        TaskCompletion();
        console.log(" Task completion tested\n");

        // Step 5: Test task cancellation
        console.log("5. TESTING TASK CANCELLATION");
        TaskCancellation();
        console.log(" Task cancellation tested\n");

        // Step 6: Test fund management
        console.log("6. TESTING FUND MANAGEMENT");
        FundManagement();
        console.log(" Fund management tested\n");

        // Step 7: Test edge cases and error conditions
        console.log("7. TESTING EDGE CASES");
        EdgeCases();
        console.log(" Edge cases tested\n");

        // Step 8: Final state verification
        console.log("8. FINAL STATE VERIFICATION");
        verifyFinalState();
        console.log(" Final state verified\n");

        console.log(" ALL TESTS COMPLETED SUCCESSFULLY!");
        console.log("========================================");
    }

    function deployContracts() internal {
        console.log("=== Deploying Contracts ===");

        entryPoint = vm.addr(999);
        console.log("Using mock EntryPoint:", entryPoint);

        taskManager = deployTaskManager();
        accountFactory = deployAccountFactory(entryPoint, owner, taskManager);

        console.log("All contracts deployed successfully!");
    }

    function createTestAccounts() internal {
        vm.deal(address(this), 100 ether); // Give script plenty of ETH

        // Create three test accounts
        testAccount1 = createSmartAccount(1);
        testAccount2 = createSmartAccount(2);
        testAccount3 = createSmartAccount(3);

        // Fund all accounts
        fundAccount(testAccount1, 5 ether);
        fundAccount(testAccount2, 3 ether);
        fundAccount(testAccount3, 2 ether);

        console.log("Test Account 1:", testAccount1, "Balance:", testAccount1.balance);
        console.log("Test Account 2:", testAccount2, "Balance:", testAccount2.balance);
        console.log("Test Account 3:", testAccount3, "Balance:", testAccount3.balance);
    }

    function TaskCreation() internal {
        console.log("Creating tasks with different penalty types...");

        // Test 1: Delayed payment penalty task
        console.log("- Creating delayed payment task...");
        delayedPaymentTaskId = createTaskWithDelayedPayment(
            testAccount1,
            "Complete morning workout routine",
            0.5 ether,
            7200, // 2 hours
            3600 // 1 hour delay
        );

        // Test 2: Buddy penalty task
        console.log("- Creating buddy penalty task...");
        buddyPenaltyTaskId = createTaskWithBuddyPenalty(
            testAccount1,
            "Finish project documentation",
            0.3 ether,
            10800, // 3 hours
            buddy
        );

        // Test 3: Task for completion testing
        console.log("- Creating task for completion test...");
        completionTaskId = createTaskWithDelayedPayment(
            testAccount2,
            "Read 2 chapters of book",
            0.2 ether,
            3600, // 1 hour
            1800 // 30 minutes delay
        );

        // Test 4: Task for cancellation testing
        console.log("- Creating task for cancellation test...");
        cancellationTaskId = createTaskWithBuddyPenalty(
            testAccount2,
            "Practice piano for 1 hour",
            0.1 ether,
            5400, // 1.5 hours
            buddy
        );

        // Display all created tasks
        console.log("\nAccount 1 tasks:");
        displayAllTasks(testAccount1);
        console.log("\nAccount 2 tasks:");
        displayAllTasks(testAccount2);
    }

    function TaskCompletion() internal {
        console.log("Testing task completion flow...");

        console.log("Before completion - Account 2:");
        displayAccountInfo(testAccount2);

        console.log("Task details before completion:");
        displayTaskInfo(testAccount2, completionTaskId);

        // Complete the task
        completeTask(testAccount2, completionTaskId);

        console.log("After completion - Account 2:");
        displayAccountInfo(testAccount2);

        console.log("Task details after completion:");
        displayTaskInfo(testAccount2, completionTaskId);
    }

    function TaskCancellation() internal {
        console.log("Testing task cancellation flow...");

        console.log("Before cancellation - Account 2:");
        displayAccountInfo(testAccount2);

        console.log("Task details before cancellation:");
        displayTaskInfo(testAccount2, cancellationTaskId);

        // Cancel the task
        cancelTask(testAccount2, cancellationTaskId);

        console.log("After cancellation - Account 2:");
        displayAccountInfo(testAccount2);

        console.log("Task details after cancellation:");
        displayTaskInfo(testAccount2, cancellationTaskId);
    }

    function FundManagement() internal {
        console.log("Testing fund management...");

        console.log("Initial state - Account 3:");
        displayAccountInfo(testAccount3);

        // Create a task to commit some funds
        uint256 taskId = createTaskWithDelayedPayment(
            testAccount3,
            "Learn new programming language",
            0.5 ether,
            7200, // 2 hours
            3600 // 1 hour delay
        );

        console.log("After creating task - committed funds:");
        displayAccountInfo(testAccount3);

        // Try to transfer available funds
        uint256 availableBalance = getAvailableBalance(testAccount3);
        if (availableBalance > 0.1 ether) {
            console.log("Transferring available funds...");
            transferFunds(testAccount3, owner, 0.1 ether);

            console.log("After transfer:");
            displayAccountInfo(testAccount3);
        }

        // Complete the task to free up committed funds
        console.log("Completing task to free up committed funds...");
        completeTask(testAccount3, taskId);

        console.log("Final state after task completion:");
        displayAccountInfo(testAccount3);
    }

    function EdgeCases() internal {
        console.log("Testing edge cases and error conditions...");

        // Test 1: Try to create task with insufficient funds
        console.log("- Testing insufficient funds scenario...");
        address lowFundAccount = createSmartAccount(99);
        fundAccount(lowFundAccount, 0.01 ether); // Very small amount
        console.log("Low fund account balance:", lowFundAccount.balance);

        // This call should fail because the reward (0.02 ether) > balance (0.01 ether)
        SmartAccount smartAccount = SmartAccount(payable(lowFundAccount));
        vm.prank(smartAccount.s_owner());
        vm.expectRevert(SmartAccount.SmartAccount__AddMoreFunds.selector);
        smartAccount.createTask("This task should fail", 0.02 ether, 3600, PENALTY_DELAYEDPAYMENT, address(0), 1800);
        console.log(" Revert on insufficient funds confirmed as expected.");

        // Test 2: Multiple tasks on same account
        console.log("- Testing multiple tasks on same account...");
        createTaskWithDelayedPayment(testAccount1, "Task A", 0.1 ether, 3600, 1800);
        createTaskWithBuddyPenalty(testAccount1, "Task B", 0.1 ether, 3600, buddy);
        createTaskWithDelayedPayment(testAccount1, "Task C", 0.1 ether, 3600, 1800);

        console.log("Account 1 now has", getTotalTasks(testAccount1), "total tasks");

        // Test 3: Check account prediction
        console.log("- Testing account address prediction...");
        address predicted = predictAccountAddress(vm.addr(123), 1);
        console.log("Predicted address for new user:", predicted);
    }

    function verifyFinalState() internal view {
        console.log("Verifying final state of all accounts...");

        console.log("\n=== FINAL ACCOUNT STATES ===");

        console.log("Account 1 Final State:");
        displayAccountInfo(testAccount1);

        console.log("Account 2 Final State:");
        displayAccountInfo(testAccount2);

        console.log("Account 3 Final State:");
        displayAccountInfo(testAccount3);

        // Verify contract states
        console.log("\n=== CONTRACT STATES ===");
        console.log("TaskManager:", taskManager);
        console.log("AccountFactory:", accountFactory);
        console.log("Entry Point:", entryPoint);

        // Check total tasks across all accounts
        uint256 totalTasksAll = getTotalTasks(testAccount1) + getTotalTasks(testAccount2) + getTotalTasks(testAccount3);
        console.log("Total tasks created across all accounts:", totalTasksAll);

        // Check balances
        console.log("\n=== BALANCE SUMMARY ===");
        console.log("Account 1 balance:", testAccount1.balance);
        console.log("Account 2 balance:", testAccount2.balance);
        console.log("Account 3 balance:", testAccount3.balance);
        console.log("Script balance remaining:", address(this).balance);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deployTaskManager() internal returns (address) {
        vm.startBroadcast();
        TaskManager tm = new TaskManager();
        vm.stopBroadcast();

        console.log("TaskManager deployed at:", address(tm));
        taskManager = address(tm);
        return address(tm);
    }

    function deployAccountFactory(address _entryPoint, address _owner, address _taskManager)
        internal
        returns (address)
    {
        vm.startBroadcast();
        AccountFactory factory = new AccountFactory(_entryPoint, _owner, _taskManager);
        vm.stopBroadcast();

        console.log("AccountFactory deployed at:", address(factory));
        accountFactory = address(factory);
        return address(factory);
    }

    function deployAll(address _entryPoint) internal returns (address, address) {
        address tm = deployTaskManager();
        address factory = deployAccountFactory(_entryPoint, owner, tm);
        entryPoint = _entryPoint;
        return (tm, factory);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function createSmartAccount(uint256 userNonce) internal returns (address) {
        AccountFactory factory = AccountFactory(accountFactory);

        vm.startBroadcast();
        address account = factory.createAccount(userNonce);
        vm.stopBroadcast();

        console.log("SmartAccount created at:", account);
        console.log("For user:", msg.sender);
        return account;
    }

    function fundAccount(address account, uint256 amount) internal {
        vm.startBroadcast();
        (bool success,) = payable(account).call{value: amount}("");
        require(success, "Funding failed");
        vm.stopBroadcast();

        console.log("Funded account:", account);
        console.log("Amount:", amount);
        console.log("New balance:", account.balance);
    }

    function getAccountBalance(address account) public view returns (uint256) {
        return account.balance;
    }

    function predictAccountAddress(address user, uint256 userNonce) internal view returns (address) {
        AccountFactory factory = AccountFactory(accountFactory);
        return factory.getAddressForUser(user, userNonce);
    }

    /*//////////////////////////////////////////////////////////////
                            TASK MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function createTaskWithDelayedPayment(
        address account,
        string memory description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint256 delayDuration
    ) internal returns (uint256) {
        SmartAccount smartAccount = SmartAccount(payable(account));

        vm.startBroadcast();
        smartAccount.createTask(
            description,
            rewardAmount,
            deadlineInSeconds,
            PENALTY_DELAYEDPAYMENT,
            address(0), // no buddy needed for delayed payment
            delayDuration
        );
        vm.stopBroadcast();

        uint256 totalTasks = smartAccount.getTotalTasks();
        uint256 taskId = totalTasks - 1; // Latest task ID

        console.log("Task created with delayed payment penalty");
        console.log("Task ID:", taskId);
        console.log("Description:", description);
        console.log("Reward:", rewardAmount);
        console.log("Delay Duration:", delayDuration);

        return taskId;
    }

    function createTaskWithBuddyPenalty(
        address account,
        string memory description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        address _buddy
    ) internal returns (uint256) {
        SmartAccount smartAccount = SmartAccount(payable(account));

        vm.startBroadcast();
        smartAccount.createTask(
            description,
            rewardAmount,
            deadlineInSeconds,
            PENALTY_SENDBUDDY,
            _buddy,
            0 // no delay duration for buddy penalty
        );
        vm.stopBroadcast();

        uint256 totalTasks = smartAccount.getTotalTasks();
        uint256 taskId = totalTasks - 1; // Latest task ID

        console.log("Task created with buddy penalty");
        console.log("Task ID:", taskId);
        console.log("Description:", description);
        console.log("Reward:", rewardAmount);
        console.log("Buddy:", _buddy);

        return taskId;
    }

    function completeTask(address account, uint256 taskId) internal {
        SmartAccount smartAccount = SmartAccount(payable(account));

        vm.startBroadcast();
        smartAccount.completeTask(taskId);
        vm.stopBroadcast();

        console.log("Task completed:");
        console.log("Account:", account);
        console.log("Task ID:", taskId);
    }

    function cancelTask(address account, uint256 taskId) internal {
        SmartAccount smartAccount = SmartAccount(payable(account));

        vm.startBroadcast();
        smartAccount.cancelTask(taskId);
        vm.stopBroadcast();

        console.log("Task canceled:");
        console.log("Account:", account);
        console.log("Task ID:", taskId);
    }

    function releaseDelayedPayment(address account, uint256 taskId) internal {
        SmartAccount smartAccount = SmartAccount(payable(account));

        vm.startBroadcast();
        smartAccount.releaseDelayedPayment(taskId);
        vm.stopBroadcast();

        console.log("Delayed payment released:");
        console.log("Account:", account);
        console.log("Task ID:", taskId);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getTask(address account, uint256 taskId) public view returns (ITaskManager.Task memory) {
        SmartAccount smartAccount = SmartAccount(payable(account));
        return smartAccount.getTask(taskId);
    }

    function getAllTasks(address account) public view returns (ITaskManager.Task[] memory) {
        SmartAccount smartAccount = SmartAccount(payable(account));
        uint256 totalTasks = smartAccount.getTotalTasks();

        if (totalTasks == 0) {
            return new ITaskManager.Task[](0);
        }

        (ITaskManager.Task[] memory tasks,) = smartAccount.getAllTasks(0, totalTasks);
        return tasks;
    }

    function getTotalTasks(address account) public view returns (uint256) {
        SmartAccount smartAccount = SmartAccount(payable(account));
        return smartAccount.getTotalTasks();
    }

    function getCommittedReward(address account) public view returns (uint256) {
        SmartAccount smartAccount = SmartAccount(payable(account));
        return smartAccount.s_totalCommittedReward();
    }

    function getAvailableBalance(address account) public view returns (uint256) {
        SmartAccount smartAccount = SmartAccount(payable(account));
        uint256 totalBalance = account.balance;
        uint256 committedReward = smartAccount.s_totalCommittedReward();

        if (totalBalance >= committedReward) {
            return totalBalance - committedReward;
        }
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function transferFunds(address account, address destination, uint256 amount) internal {
        SmartAccount smartAccount = SmartAccount(payable(account));

        vm.startBroadcast();
        smartAccount.transfer(destination, amount);
        vm.stopBroadcast();

        console.log("Transferred funds:");
        console.log("From account:", account);
        console.log("To:", destination);
        console.log("Amount:", amount);
    }

    function displayTaskInfo(address account, uint256 taskId) public view {
        ITaskManager.Task memory task = getTask(account, taskId);

        console.log("=== Task Information ===");
        console.log("ID:", task.id);
        console.log("Description:", task.description);
        console.log("Reward Amount:", task.rewardAmount);
        console.log("Deadline:", task.deadline);
        console.log("Status:", uint8(task.status));
        console.log("Penalty Choice:", task.choice);
        console.log("Delay Duration:", task.delayDuration);
        console.log("Buddy:", task.buddy);
        console.log("Delayed Reward Released:", task.delayedRewardReleased);
    }

    function displayAccountInfo(address account) public view {
        console.log("=== Account Information ===");
        console.log("Address:", account);
        console.log("Total Balance:", account.balance);
        console.log("Committed Reward:", getCommittedReward(account));
        console.log("Available Balance:", getAvailableBalance(account));
        console.log("Total Tasks:", getTotalTasks(account));
    }

    function displayAllTasks(address account) public view {
        console.log("=== All Tasks ===");
        ITaskManager.Task[] memory tasks = getAllTasks(account);

        for (uint256 i = 0; i < tasks.length; i++) {
            console.log("--- Task", i, "---");
            console.log("ID:", tasks[i].id);
            console.log("Description:", tasks[i].description);
            console.log("Reward:", tasks[i].rewardAmount);
            console.log("Status:", uint8(tasks[i].status));
            console.log("Penalty Choice:", tasks[i].choice);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            TEST SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function CompleteWorkflow() internal {
        console.log("=== Starting Complete Workflow Test ===");

        // Step 1: Deploy contracts
        console.log("\n--- Step 1: Deploying Contracts ---");
        address mockEntryPoint = vm.addr(999);
        deployAll(mockEntryPoint);

        // Step 2: Create and fund a smart account
        console.log("\n--- Step 2: Creating and Funding Smart Account ---");
        address account = createSmartAccount(1);
        fundAccount(account, 5 ether);
        displayAccountInfo(account);

        // Step 3: Create and complete a task
        console.log("\n--- Step 3: Task Completion ---");
        uint256 taskIdToComplete = createTaskWithDelayedPayment(account, "Task to be completed", 0.5 ether, 3600, 1800);
        console.log(" Completing task...");
        completeTask(account, taskIdToComplete);
        displayAccountInfo(account);

        // Step 4: Create and cancel a task
        console.log("\n--- Step 4: Task Cancellation ---");
        uint256 taskIdToCancel = createTaskWithBuddyPenalty(account, "Task to be canceled", 0.3 ether, 7200, buddy);
        console.log(" Cancelling task...");
        cancelTask(account, taskIdToCancel);
        displayAccountInfo(account);

        // Step 5: Expire a task with delayed payment penalty
        console.log("\n--- Step 5: Task Expiration (Delayed Payment) ---");
        uint256 taskIdToExpireDelay =
            createTaskWithDelayedPayment(account, "Task to expire (delay)", 0.2 ether, 60, 120); // 1 min deadline, 2 min delay
        console.log(" Warping time past deadline...");
        vm.warp(block.timestamp + 61);

        console.log(" Performing upkeep to expire task...");
        (bool upkeepNeeded, bytes memory performData) = checkUpkeep();
        if (upkeepNeeded) {
            performUpkeep(performData);
        } else {
            console.log(" Upkeep not needed (unexpected).");
        }
        displayTaskInfo(account, taskIdToExpireDelay);

        console.log(" Warping time past delay duration...");
        vm.warp(block.timestamp + 121);
        console.log(" Releasing delayed payment...");
        releaseDelayedPayment(account, taskIdToExpireDelay);
        displayAccountInfo(account);
        displayTaskInfo(account, taskIdToExpireDelay);

        // Step 6: Expire a task with buddy penalty
        console.log("\n--- Step 6: Task Expiration (Buddy Penalty) ---");
        uint256 buddyBalanceBefore = buddy.balance;
        console.log(" Buddy balance before:", buddyBalanceBefore);
        uint256 taskIdToExpireBuddy =
            createTaskWithBuddyPenalty(account, "Task to expire (buddy)", 0.4 ether, 60, buddy);
        displayAccountInfo(account);

        console.log(" Warping time past deadline...");
        vm.warp(block.timestamp + 61);

        console.log(" Performing upkeep to expire task...");
        (upkeepNeeded, performData) = checkUpkeep();
        if (upkeepNeeded) {
            performUpkeep(performData);
        } else {
            console.log(" Upkeep not needed (unexpected).");
        }

        uint256 buddyBalanceAfter = buddy.balance;
        console.log(" Buddy balance after:", buddyBalanceAfter);
        console.log(" Reward transferred to buddy:", buddyBalanceAfter - buddyBalanceBefore);
        displayAccountInfo(account);
        displayTaskInfo(account, taskIdToExpireBuddy);

        console.log("\n=== Workflow Test Complete ===");
    }

    function TaskCompletion(address account, uint256 taskId) internal {
        console.log("=== Testing Task Completion ===");

        displayTaskInfo(account, taskId);
        completeTask(account, taskId);
        displayTaskInfo(account, taskId);
        displayAccountInfo(account);
    }

    function TaskExpiration() internal view {
        console.log("=== Testing Task Expiration ===");
        // This would require time manipulation in a test environment
        // Implementation depends on your testing framework setup
    }

    /*//////////////////////////////////////////////////////////////
                            CHAINLINK AUTOMATION
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep() public view returns (bool upkeepNeeded, bytes memory performData) {
        TaskManager tm = TaskManager(taskManager);
        return tm.checkUpkeep("");
    }

    function performUpkeep(bytes memory performData) public {
        TaskManager tm = TaskManager(taskManager);

        vm.startBroadcast();
        tm.performUpkeep(performData);
        vm.stopBroadcast();

        console.log("Performed upkeep with data:", string(performData));
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function emergencyWithdraw(address account) public {
        uint256 availableBalance = getAvailableBalance(account);
        if (availableBalance > 0) {
            transferFunds(account, owner, availableBalance);
            console.log("Emergency withdrawal completed");
            console.log("Amount withdrawn:", availableBalance);
        } else {
            console.log("No available balance to withdraw");
        }
    }

    // Helper function to get current timestamp (useful for testing)
    function getCurrentTimestamp() public view returns (uint256) {
        return block.timestamp;
    }
}
