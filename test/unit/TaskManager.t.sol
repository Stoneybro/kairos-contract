// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {TaskManager} from "src/TaskManager.sol";
import {SimpleAccount} from "src/SimpleAccount.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract TaskManagerTest is Test {
    TaskManager taskManager;
    SimpleAccount account;
    HelperConfig helperConfig;
    HelperConfig.NetworkConfig config;
    
    address owner = makeAddr("OWNER");
    address user = makeAddr("USER");
    address buddy = makeAddr("BUDDY");
    
    uint256 constant REWARD_AMOUNT = 1 ether;
    uint256 constant DURATION = 1 days;
    string constant TASK_DESCRIPTION = "Test task";

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);

    function setUp() public {
        // Setup helper config
        helperConfig = new HelperConfig();
        config = helperConfig.getConfig();
        
        // Create and initialize SimpleAccount
        account = new SimpleAccount();
        account.initialize(owner, address(config.entryPoint));
        vm.deal(address(account), 10 ether);
        
        // Create TaskManager with SimpleAccount as owner
        taskManager = new TaskManager(address(account));
        
        // Link TaskManager to SimpleAccount
        vm.prank(owner);
        account.linkTaskManager(address(taskManager));
        
        // Set penalty for account (required for task creation)
        vm.prank(owner);
        account.setDelayPenalty(1 days);
    }

    /*//////////////////////////////////////////////////////////////
                            TASK CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateTask_Success() public {
        vm.expectEmit(true, false, false, true);
        emit TaskCreated(0, TASK_DESCRIPTION, REWARD_AMOUNT);
        
        vm.prank(address(account));
        (uint256 taskId, bool success) = taskManager.createTask(
            TASK_DESCRIPTION, 
            REWARD_AMOUNT, 
            DURATION, 
            1, // PENALTY_DELAYEDPAYMENT
            1 days
        );
        
        assertTrue(success);
        assertEq(taskId, 0);
        
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.id, taskId);
        assertEq(task.description, TASK_DESCRIPTION);
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        assertEq(task.deadline, block.timestamp + DURATION);
        assertTrue(task.valid);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.PENDING));
        assertEq(task.choice, 1);
        assertEq(task.delayDuration, 1 days);
    }

    function test_CreateTask_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(user);
        taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
    }

    function test_CreateMultipleTasks() public {
        // Create first task
        vm.prank(address(account));
        (uint256 taskId1, bool success1) = taskManager.createTask("Task 1", 1 ether, 1 days, 1, 1 days);
        assertTrue(success1);
        assertEq(taskId1, 0);
        
        // Create second task
        vm.prank(address(account));
        (uint256 taskId2, bool success2) = taskManager.createTask("Task 2", 2 ether, 2 days, 2, 2 days);
        assertTrue(success2);
        assertEq(taskId2, 1);
        
        assertEq(taskManager.getTotalTasks(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                          TASK COMPLETION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CompleteTask_Success() public {
        // Create task first
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.expectEmit(true, false, false, false);
        emit TaskCompleted(taskId);
        
        vm.prank(address(account));
        taskManager.completeTask(taskId);
        
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.COMPLETED));
    }

    function test_CompleteTask_OnlyOwner() public {
        // Create task first
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.expectRevert();
        vm.prank(user);
        taskManager.completeTask(taskId);
    }

    function test_CompleteTask_NonExistentTask() public {
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        vm.prank(address(account));
        taskManager.completeTask(999);
    }

    function test_CompleteTask_AlreadyCompleted() public {
        // Create and complete task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.prank(address(account));
        taskManager.completeTask(taskId);
        
        // Try to complete again
        vm.expectRevert(TaskManager.TaskManager__TaskAlreadyCompleted.selector);
        vm.prank(address(account));
        taskManager.completeTask(taskId);
    }

    function test_CompleteTask_ExpiredTask() public {
        // Create task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        // Fast forward past deadline
        vm.warp(block.timestamp + DURATION + 1);
        
        // Expire the task first
        taskManager.expireTask(taskId);
        
        // Try to complete expired task
        vm.expectRevert(TaskManager.TaskManager__TaskHasExpired.selector);
        vm.prank(address(account));
        taskManager.completeTask(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                          TASK CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CancelTask_Success() public {
        // Create task first
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.expectEmit(true, false, false, false);
        emit TaskCanceled(taskId);
        
        vm.prank(address(account));
        taskManager.cancelTask(taskId);
        
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.CANCELED));
    }

    function test_CancelTask_OnlyOwner() public {
        // Create task first
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.expectRevert();
        vm.prank(user);
        taskManager.cancelTask(taskId);
    }

    function test_CancelTask_AlreadyCanceled() public {
        // Create and cancel task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.prank(address(account));
        taskManager.cancelTask(taskId);
        
        // Try to cancel again
        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
        vm.prank(address(account));
        taskManager.cancelTask(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                          TASK EXPIRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExpireTask_Success() public {
        // Create task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        // Fast forward past deadline
        vm.warp(block.timestamp + DURATION + 1);
        
        vm.expectEmit(true, false, false, false);
        emit TaskExpired(taskId);
        
        taskManager.expireTask(taskId);
        
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.EXPIRED));
    }

    function test_ExpireTask_NotYetExpired() public {
        // Create task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        vm.expectRevert(TaskManager.TaskManager__TaskNotYetExpired.selector);
        taskManager.expireTask(taskId);
    }

    function test_ExpireTask_AlreadyExpired() public {
        // Create task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        // Fast forward and expire
        vm.warp(block.timestamp + DURATION + 1);
        taskManager.expireTask(taskId);
        
        // Try to expire again
        vm.expectRevert(TaskManager.TaskManager__TaskHasExpired.selector);
        taskManager.expireTask(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                          CHAINLINK AUTOMATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CheckUpkeep_NoExpiredTasks() public {
        // Create task that hasn't expired
        vm.prank(address(account));
        taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_CheckUpkeep_WithExpiredTask() public {
        // Create task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        // Fast forward past deadline
        vm.warp(block.timestamp + DURATION + 1);
        
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertTrue(performData.length > 0);
        
        (uint256[] memory expiredTaskIds, uint256 count) = abi.decode(performData, (uint256[], uint256));
        assertEq(count, 1);
        assertEq(expiredTaskIds[0], taskId);
    }

    function test_PerformUpkeep_Success() public {
        // Create task
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        // Fast forward past deadline
        vm.warp(block.timestamp + DURATION + 1);
        
        // Get upkeep data
        (, bytes memory performData) = taskManager.checkUpkeep("");
        
        // Perform upkeep
        taskManager.performUpkeep(performData);
        
        // Check task is expired
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.EXPIRED));
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetTask_Success() public {
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.id, taskId);
        assertEq(task.description, TASK_DESCRIPTION);
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        assertTrue(task.valid);
    }

    function test_GetTask_NonExistent() public {
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        taskManager.getTask(999);
    }

    function test_GetTotalTasks() public {
        assertEq(taskManager.getTotalTasks(), 0);
        
        vm.prank(address(account));
        taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        assertEq(taskManager.getTotalTasks(), 1);
        
        vm.prank(address(account));
        taskManager.createTask("Task 2", REWARD_AMOUNT, DURATION, 1, 1 days);
        assertEq(taskManager.getTotalTasks(), 2);
    }

    function test_IsValidTask() public {
        assertFalse(taskManager.isValidTask(0));
        
        vm.prank(address(account));
        taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        assertTrue(taskManager.isValidTask(0));
        assertFalse(taskManager.isValidTask(1));
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MultipleTasksWithDifferentDeadlines() public {
        // Create tasks with different deadlines
        vm.prank(address(account));
        (uint256 taskId1,) = taskManager.createTask("Task 1", REWARD_AMOUNT, 1 days, 1, 1 days);
        
        vm.prank(address(account));
         taskManager.createTask("Task 2", REWARD_AMOUNT, 2 days, 1, 1 days);
        
        vm.prank(address(account));
         taskManager.createTask("Task 3", REWARD_AMOUNT, 3 days, 1, 1 days);
        
        // Fast forward to expire first task only
        vm.warp(block.timestamp + 1 days + 1);
        
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        (uint256[] memory expiredTaskIds, uint256 count) = abi.decode(performData, (uint256[], uint256));
        assertEq(count, 1);
        assertEq(expiredTaskIds[0], taskId1);
    }

    function test_TaskStatusTransitions() public {
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        // Initial state
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.PENDING));
        
        // Complete task
        vm.prank(address(account));
        taskManager.completeTask(taskId);
        
        task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.COMPLETED));
    }

    function test_NextExpiringTaskTracking() public {
        // Create tasks with different deadlines
        vm.prank(address(account));
        taskManager.createTask("Task 1", REWARD_AMOUNT, 3 days, 1, 1 days);
        
        vm.prank(address(account));
        taskManager.createTask("Task 2", REWARD_AMOUNT, 1 days, 1, 1 days); // This should be next expiring
        
        vm.prank(address(account));
        taskManager.createTask("Task 3", REWARD_AMOUNT, 2 days, 1, 1 days);
        
        // The nextExpiringTaskId should be task 1 (shortest deadline)
        assertEq(taskManager.nextExpiringTaskId(), 1);
        assertEq(taskManager.nextDeadline(), block.timestamp + 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CreateTask(uint256 rewardAmount, uint256 duration) public {
        rewardAmount = bound(rewardAmount, 1 wei, 100 ether);
        duration = bound(duration, 1 seconds, 365 days);
        
        vm.prank(address(account));
        (uint256 taskId, bool success) = taskManager.createTask(
            "Fuzz task", 
            rewardAmount, 
            duration, 
            1, 
            1 days
        );
        
        assertTrue(success);
        
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.rewardAmount, rewardAmount);
        assertEq(task.deadline, block.timestamp + duration);
    }

    function testFuzz_TaskOperations(uint8 operation, uint256 timeWarp) public {
        // Create a task first
        vm.prank(address(account));
        (uint256 taskId,) = taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DURATION, 1, 1 days);
        
        operation = uint8(bound(operation, 0, 2));
        timeWarp = bound(timeWarp, 0, DURATION * 2);
        
        vm.warp(block.timestamp + timeWarp);
        
        if (operation == 0) {
            // Try to complete
            try taskManager.completeTask(taskId) {
                TaskManager.Task memory task = taskManager.getTask(taskId);
                assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.COMPLETED));
            } catch {
                // Expected if task expired or other conditions
            }
        } else if (operation == 1) {
            // Try to cancel
            try taskManager.cancelTask(taskId) {
                TaskManager.Task memory task = taskManager.getTask(taskId);
                assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.CANCELED));
            } catch {
                // Expected if task expired or other conditions
            }
        } else {
            // Try to expire
            try taskManager.expireTask(taskId) {
                TaskManager.Task memory task = taskManager.getTask(taskId);
                assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.EXPIRED));
            } catch {
                // Expected if not yet expired
            }
        }
    }
}