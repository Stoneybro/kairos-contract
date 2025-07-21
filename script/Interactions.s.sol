// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {SmartAccount} from "../src/SmartAccount.sol";
import {TaskManager} from "../src/TaskManager.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract InteractionScript is Script {
    // Deployer private key and address
    uint256 private constant DEPLOYER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER_ADDRESS = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    
    // Mock EntryPoint address (replace with actual EntryPoint address on your network)
    address private constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    
    // Test addresses for buddy system
    address private constant BUDDY_ADDRESS = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address private constant USER_ADDRESS = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    
    AccountFactory public accountFactory;
    SmartAccount public userAccount;
    TaskManager public taskManager;
    
    function run() external {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
        
        console2.log("=== Task Management System Interaction Script ===");
        console2.log("Deployer Address:", DEPLOYER_ADDRESS);
        console2.log("Entry Point:", ENTRY_POINT);
        
        // Step 1: Deploy AccountFactory
        deployAccountFactory();
        
        // Step 2: Create a user account
        createUserAccount();
        
        // Step 3: Fund the user account
        fundUserAccount();
        
        // Step 4: Test task creation scenarios
        testTaskCreationScenarios();
        
        // Step 5: Test task completion
        testTaskCompletion();
        
        // Step 6: Test task cancellation
        testTaskCancellation();
        
        // Step 7: Test penalty mechanisms
        testPenaltyMechanisms();
        
        // Step 8: Test edge cases and error conditions
        testErrorConditions();
        
        vm.stopBroadcast();
        
        console2.log("=== Script Execution Completed ===");
    }
    
    function deployAccountFactory() internal {
        console2.log("\n--- Step 1: Deploying AccountFactory ---");
        
        accountFactory = new AccountFactory(ENTRY_POINT, DEPLOYER_ADDRESS);
        console2.log("AccountFactory deployed at:", address(accountFactory));
        console2.log("Implementation address:", accountFactory.implementation());
    }
    
    function createUserAccount() internal {
        console2.log("\n--- Step 2: Creating User Account ---");
        
        // Switch to user for account creation
        vm.stopBroadcast();
        vm.startBroadcast(vm.addr(0x2));
        
        uint256 userNonce = 0;
        address predictedAddress = accountFactory.getAddress(userNonce);
        console2.log("Predicted account address:", predictedAddress);
        
        address createdAccount = accountFactory.createAccount(userNonce);
        console2.log("Created account address:", createdAccount);
        
        require(createdAccount == predictedAddress, "Address mismatch");
        
        userAccount = SmartAccount(payable(createdAccount));
        taskManager = TaskManager(userAccount.getTaskManagerAddress());
        
        console2.log("Task Manager address:", address(taskManager));
        console2.log("Account owner:", userAccount.s_owner());
        
        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    }
    
    function fundUserAccount() internal {
        console2.log("\n--- Step 3: Funding User Account ---");
        
        uint256 fundingAmount = 10 ether;
        (bool success,) = payable(address(userAccount)).call{value: fundingAmount}("");
        require(success, "Funding failed");
        
        console2.log("Account balance:", address(userAccount).balance);
        console2.log("Committed rewards:", userAccount.s_totalCommittedReward());
    }
    
    function testTaskCreationScenarios() internal {
        console2.log("\n--- Step 4: Testing Task Creation Scenarios ---");
        
        // Switch to account owner for task operations
        vm.stopBroadcast();
        vm.startBroadcast(vm.addr(0x2));
        
        // Scenario 1: Create task with delayed payment penalty
        console2.log("\nScenario 1: Delayed Payment Penalty");
        userAccount.createTask(
            "Complete daily workout",
            1 ether,                    // reward amount
            3600,                       // deadline in seconds (1 hour)
            1,                          // PENALTY_DELAYEDPAYMENT
            address(0),                 // buddy not needed for delayed payment
            86400                       // delay duration (1 day)
        );
        
        // Scenario 2: Create task with buddy penalty
        console2.log("Scenario 2: Send to Buddy Penalty");
        userAccount.createTask(
            "Read 30 pages of book",
            0.5 ether,                  // reward amount
            7200,                       // deadline in seconds (2 hours)
            2,                          // PENALTY_SENDBUDDY
            BUDDY_ADDRESS,              // buddy address
            0                           // delay duration not needed
        );
        
        // Scenario 3: Create multiple tasks
        console2.log("Scenario 3: Multiple Tasks");
        for (uint i = 0; i < 3; i++) {
            userAccount.createTask(
                string(abi.encodePacked("Task ", vm.toString(i + 3))),
                0.2 ether,
                1800,                   // 30 minutes
                1,                      // PENALTY_DELAYEDPAYMENT
                address(0),
                3600                    // 1 hour delay
            );
        }
        
        uint256 totalTasks = userAccount.getTotalTasks();
        console2.log("Total tasks created:", totalTasks);
        console2.log("Updated committed rewards:", userAccount.s_totalCommittedReward());
        
        // Display all tasks
        TaskManager.Task[] memory allTasks = userAccount.getAllTasks();
        for (uint i = 0; i < allTasks.length; i++) {
            console2.log("Task", i, "- Description:", allTasks[i].description);
            console2.log("  Reward:", allTasks[i].rewardAmount);
            console2.log("  Deadline:", allTasks[i].deadline);
            console2.log("  Status:", uint(allTasks[i].status));
        }
        
        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    }
    
    function testTaskCompletion() internal {
        console2.log("\n--- Step 5: Testing Task Completion ---");
        
        vm.stopBroadcast();
        vm.startBroadcast(vm.addr(0x2));
        
        uint256 balanceBefore = vm.addr(0x2).balance;
        console2.log("User balance before completion:", balanceBefore);
        
        // Complete first task (task ID 0)
        userAccount.completeTask(0);
        
        uint256 balanceAfter = vm.addr(0x2).balance;
        console2.log("User balance after completion:", balanceAfter);
        console2.log("Reward received:", balanceAfter - balanceBefore);
        console2.log("Updated committed rewards:", userAccount.s_totalCommittedReward());
        
        // Verify task status
        TaskManager.Task memory completedTask = userAccount.getTask(0);
        console2.log("Task 0 status:", uint(completedTask.status));
        
        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    }
    
    function testTaskCancellation() internal {
        console2.log("\n--- Step 6: Testing Task Cancellation ---");
        
        vm.stopBroadcast();
        vm.startBroadcast(vm.addr(0x2));
        
        uint256 committedBefore = userAccount.s_totalCommittedReward();
        console2.log("Committed rewards before cancellation:", committedBefore);
        
        // Cancel task ID 2
        userAccount.cancelTask(2);
        
        uint256 committedAfter = userAccount.s_totalCommittedReward();
        console2.log("Committed rewards after cancellation:", committedAfter);
        console2.log("Rewards freed up:", committedBefore - committedAfter);
        
        // Verify task status
        TaskManager.Task memory canceledTask = userAccount.getTask(2);
        console2.log("Task 2 status:", uint(canceledTask.status));
        
        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    }
    
    function testPenaltyMechanisms() internal {
        console2.log("\n--- Step 7: Testing Penalty Mechanisms ---");
        
        // Fast forward time to make task 1 expire (buddy penalty)
        console2.log("Fast forwarding time to expire task 1...");
        vm.warp(block.timestamp + 7300); // Move past 2 hour deadline
        
        // Simulate Chainlink automation calling performUpkeep
        console2.log("Simulating Chainlink automation...");
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        console2.log("Upkeep needed:", upkeepNeeded);
        
        if (upkeepNeeded) {
            uint256 buddyBalanceBefore = BUDDY_ADDRESS.balance;
            console2.log("Buddy balance before penalty:", buddyBalanceBefore);
            
            taskManager.performUpkeep(performData);
            
            uint256 buddyBalanceAfter = BUDDY_ADDRESS.balance;
            console2.log("Buddy balance after penalty:", buddyBalanceAfter);
            console2.log("Penalty amount received by buddy:", buddyBalanceAfter - buddyBalanceBefore);
            
            // Check task status
            TaskManager.Task memory expiredTask = userAccount.getTask(1);
            console2.log("Task 1 status:", uint(expiredTask.status));
        }
        
        // Test delayed payment mechanism
        console2.log("\nTesting delayed payment mechanism...");
        
        // Fast forward to expire task 3 (delayed payment penalty)
        vm.warp(block.timestamp + 1900); // Move past 30 min deadline
        
        (upkeepNeeded, performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
            console2.log("Task 3 expired with delayed payment penalty");
        }
        
        // Try to release delayed payment before delay duration
        vm.stopBroadcast();
        vm.startBroadcast(vm.addr(0x2));
        TaskManager.Task memory task3 = userAccount.getTask(3);
        vm.warp(task3.deadline+task3.delayDuration-10);
        try userAccount.releaseDelayedPayment(3) {
            console2.log("ERROR: Should not be able to release payment early");
        } catch {
            console2.log("Correctly prevented early payment release");
        }
        
        // Fast forward past delay duration
        console2.log("Fast forwarding past delay duration...");
        vm.warp(task3.deadline+task3.delayDuration+10); // Move past 1 hour delay
        

        uint256 userBalanceBefore = vm.addr(0x2).balance;
        userAccount.releaseDelayedPayment(3);
        uint256 userBalanceAfter = vm.addr(0x2).balance;
        
        console2.log("Delayed payment released:", userBalanceAfter - userBalanceBefore);
        
        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    }
    
    function testErrorConditions() internal {
        console2.log("\n--- Step 8: Testing Error Conditions ---");
        
        vm.stopBroadcast();
        vm.startBroadcast(vm.addr(0x2));
        
        // Test insufficient funds for task creation
        console2.log("Testing insufficient funds scenario...");
        try userAccount.createTask(
            "Impossible task",
            100 ether,                  // More than account balance
            3600,
            1,
            address(0),
            86400
        ) {
            console2.log("ERROR: Should have failed due to insufficient funds");
        } catch {
            console2.log("Correctly prevented task creation with insufficient funds");
        }
        
        // Test invalid penalty configurations
        console2.log("Testing invalid penalty configurations...");
        
        // No penalty selected
        try userAccount.createTask(
            "No penalty task",
            0.1 ether,
            3600,
            0,                          // No penalty choice
            address(0),
            0
        ) {
            console2.log("ERROR: Should have failed - no penalty selected");
        } catch {
            console2.log("Correctly prevented task creation without penalty choice");
        }
        
        // Buddy penalty without buddy address
        try userAccount.createTask(
            "Buddy task without buddy",
            0.1 ether,
            3600,
            2,                          // PENALTY_SENDBUDDY
            address(0),                 // No buddy address
            0
        ) {
            console2.log("ERROR: Should have failed - buddy penalty without address");
        } catch {
            console2.log("Correctly prevented buddy penalty without buddy address");
        }
        
        // Delayed payment without delay duration
        try userAccount.createTask(
            "Delayed payment without duration",
            0.1 ether,
            3600,
            1,                          // PENALTY_DELAYEDPAYMENT
            address(0),
            0                           // No delay duration
        ) {
            console2.log("ERROR: Should have failed - delayed payment without duration");
        } catch {
            console2.log("Correctly prevented delayed payment without duration");
        }
        
        // Test zero reward amount
        try userAccount.createTask(
            "Zero reward task",
            0,                          // Zero reward
            3600,
            1,
            address(0),
            86400
        ) {
            console2.log("ERROR: Should have failed - zero reward");
        } catch {
            console2.log("Correctly prevented zero reward task");
        }
        
        // Test operations on non-existent tasks
        try userAccount.completeTask(999) {
            console2.log("ERROR: Should have failed - non-existent task");
        } catch {
            console2.log("Correctly prevented operation on non-existent task");
        }
        
        // Test double completion
        try userAccount.completeTask(0) {
            console2.log("ERROR: Should have failed - task already completed");
        } catch {
            console2.log("Correctly prevented double completion");
        }
        
        // Test withdrawal of committed rewards
        try userAccount.transfer(USER_ADDRESS, address(userAccount).balance) {
            console2.log("ERROR: Should have failed - trying to withdraw committed rewards");
        } catch {
            console2.log("Correctly prevented withdrawal of committed rewards");
        }
        
        // Test valid transfer
        uint256 availableBalance = address(userAccount).balance - userAccount.s_totalCommittedReward();
        if (availableBalance > 0) {
            userAccount.transfer(USER_ADDRESS, availableBalance);
            console2.log("Successfully transferred available balance:", availableBalance);
        }
        
        vm.stopBroadcast();
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    }
    
    function displayFinalState() internal view {
        console2.log("\n=== Final State Summary ===");
        console2.log("Account balance:", address(userAccount).balance);
        console2.log("Committed rewards:", userAccount.s_totalCommittedReward());
        console2.log("Total tasks:", userAccount.getTotalTasks());
        
        console2.log("\nTask Status Summary:");
        TaskManager.Task[] memory allTasks = userAccount.getAllTasks();
        for (uint i = 0; i < allTasks.length; i++) {
            string memory statusName;
            if (allTasks[i].status == TaskManager.TaskStatus.PENDING) statusName = "PENDING";
            else if (allTasks[i].status == TaskManager.TaskStatus.COMPLETED) statusName = "COMPLETED";
            else if (allTasks[i].status == TaskManager.TaskStatus.CANCELED) statusName = "CANCELED";
            else if (allTasks[i].status == TaskManager.TaskStatus.EXPIRED) statusName = "EXPIRED";
            
            console2.log("Task", i, ":", statusName);
        }
    }
}