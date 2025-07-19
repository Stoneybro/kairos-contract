// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {SimpleAccount} from "src/SimpleAccount.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {TaskManager} from "src/TaskManager.sol";
import {Test, console2} from "../../lib/forge-std/src/Test.sol";

contract SimpleAccountFuzzHandler is Test {
    SimpleAccount i_account;
    TaskManager i_taskManager;
    HelperConfig.NetworkConfig i_config;
    address s_owner;

    uint256 public taskCounter;
    mapping(uint256 => bool) public activeTasks;
    uint256[] public activeTaskIds;
    
    // Track ghost variables for invariant checking
    uint256 public totalRewardsCreated;
    uint256 public totalRewardsCompleted;
    uint256 public totalRewardsCanceled;

    constructor(
        address owner,
        SimpleAccount account,
        TaskManager taskManager,
        HelperConfig.NetworkConfig memory config
    ) {
        i_account = account;
        i_taskManager = taskManager;
        i_config = config;
        s_owner = owner;
    }

    function createTask(uint256 rewardAmount, uint256 duration) external {
        // Bound inputs to reasonable ranges
        rewardAmount = bound(rewardAmount, 0.01 ether, 5 ether);
        duration = bound(duration, 1 hours, 30 days);

        uint256 committed = i_account.s_totalCommittedReward();
        uint256 balance = address(i_account).balance;

        // Ensure account has sufficient balance
        if (balance < committed + rewardAmount) {
            uint256 requiredTopUp = (committed + rewardAmount) - balance + 1 ether;
            vm.deal(address(i_account), balance + requiredTopUp);
        }

        // Verify penalty is set (required before task creation)
        if (i_account.getPenaltyChoice() == 0) {
            vm.prank(s_owner);
            i_account.setDelayPenalty(1 days);
        }

        try i_account.createTask("fuzz task", rewardAmount, duration) {
            // Track the task as active
            activeTasks[taskCounter] = true;
            activeTaskIds.push(taskCounter);
            totalRewardsCreated += rewardAmount;
            
            console2.log("Created task", taskCounter, "with reward", rewardAmount);
            taskCounter++;
        } catch Error(string memory reason) {
            console2.log("Task creation failed:", reason);
        } catch {
            console2.log("Task creation failed with unknown error");
        }
    }

    function completeTask(uint256 rand) external {
        if (activeTaskIds.length == 0) return;

        uint256 index = bound(rand, 0, activeTaskIds.length - 1);
        uint256 taskId = activeTaskIds[index];

        if (!activeTasks[taskId]) return;

        try i_account.completeTask(taskId) {
            // Get task info before marking as inactive
            TaskManager.Task memory task = i_taskManager.getTask(taskId);
            
            activeTasks[taskId] = false;
            totalRewardsCompleted += task.rewardAmount;
            _removeActiveTask(index);
            
            console2.log("Completed task", taskId, "with reward", task.rewardAmount);
        } catch Error(string memory reason) {
            console2.log("Task completion failed:", reason);
        } catch {
            console2.log("Task completion failed with unknown error");
        }
    }

    function cancelTask(uint256 rand) external {
        if (activeTaskIds.length == 0) return;

        uint256 index = bound(rand, 0, activeTaskIds.length - 1);
        uint256 taskId = activeTaskIds[index];

        if (!activeTasks[taskId]) return;

        try i_account.cancelTask(taskId) {
            // Get task info before marking as inactive
            TaskManager.Task memory task = i_taskManager.getTask(taskId);
            
            activeTasks[taskId] = false;
            totalRewardsCanceled += task.rewardAmount;
            _removeActiveTask(index);
            
            console2.log("Canceled task", taskId, "with reward", task.rewardAmount);
        } catch Error(string memory reason) {
            console2.log("Task cancellation failed:", reason);
        } catch {
            console2.log("Task cancellation failed with unknown error");
        }
    }

    function fundAccount(uint256 amount) external {
        amount = bound(amount, 0.1 ether, 50 ether);
        vm.deal(address(i_account), address(i_account).balance + amount);
        console2.log("Funded account with", amount);
    }

    function expireTask(uint256 rand) external {
        if (activeTaskIds.length == 0) return;

        uint256 index = bound(rand, 0, activeTaskIds.length - 1);
        uint256 taskId = activeTaskIds[index];

        if (!activeTasks[taskId]) return;

        try i_taskManager.getTask(taskId) returns (TaskManager.Task memory task) {
            if (task.status == TaskManager.TaskStatus.PENDING && block.timestamp > task.deadline) {
                try i_taskManager.expireTask(taskId) {
                    activeTasks[taskId] = false;
                    _removeActiveTask(index);
                    console2.log("Expired task", taskId);
                } catch {
                    console2.log("Failed to expire task", taskId);
                }
            }
        } catch {
            // Task doesn't exist or other error
        }
    }

    function _removeActiveTask(uint256 index) internal {
        if (activeTaskIds.length == 0) return;
        
        // Replace with last element and pop
        activeTaskIds[index] = activeTaskIds[activeTaskIds.length - 1];
        activeTaskIds.pop();
    }

    // Helper functions for invariant testing
    function getActiveTaskCount() external view returns (uint256) {
        return activeTaskIds.length;
    }

    function getActiveTaskIds() external view returns (uint256[] memory) {
        return activeTaskIds;
    }

    function isTaskActive(uint256 taskId) external view returns (bool) {
        return activeTasks[taskId];
    }

    function getTotalRewardsCreated() external view returns (uint256) {
        return totalRewardsCreated;
    }

    function getTotalRewardsCompleted() external view returns (uint256) {
        return totalRewardsCompleted;
    }

    function getTotalRewardsCanceled() external view returns (uint256) {
        return totalRewardsCanceled;
    }
}