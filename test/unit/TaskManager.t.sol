// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {TaskManager} from "src/TaskManager.sol";

contract TaskManagerTest is Test {
    TaskManager public taskManager;
    address public owner;
    address public buddy;
    address public nonOwner;

    // Test constants
    string constant TASK_DESCRIPTION = "Complete daily workout";
    uint256 constant REWARD_AMOUNT = 1 ether;
    uint256 constant DEADLINE_SECONDS = 3600; // 1 hour
    uint8 constant CHOICE_DELAYED_PAYMENT = 1;
    uint8 constant CHOICE_SEND_BUDDY = 2;
    uint256 constant DELAY_DURATION = 86400; // 1 day

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event TaskExpiredCallFailure(uint256 indexed taskId);
    event TaskDelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);

    function setUp() public {
        owner = address(this);
        buddy = makeAddr("buddy");
        nonOwner = makeAddr("nonOwner");
        
        taskManager = new TaskManager(owner);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testConstructorSetsOwner() public view {
        assertEq(taskManager.owner(), owner);
    }

    function testInitialState() public view {
        assertEq(taskManager.getTotalTasks(), 0);
        assertEq(taskManager.nextExpiringTaskId(), 0);
        assertEq(taskManager.nextDeadline(), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           TASK CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateTask() public {
        vm.expectEmit(true, false, false, true);
        emit TaskCreated(0, TASK_DESCRIPTION, REWARD_AMOUNT);

        (uint256 taskId, bool success) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        assertTrue(success);
        assertEq(taskId, 0);
        assertEq(taskManager.getTotalTasks(), 1);

        TaskManager.Task memory task = taskManager.getTask(0);
        assertEq(task.id, 0);
        assertEq(task.description, TASK_DESCRIPTION);
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        assertEq(task.deadline, block.timestamp + DEADLINE_SECONDS);
        assertTrue(task.valid);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.PENDING));
        assertEq(task.choice, CHOICE_DELAYED_PAYMENT);
        assertEq(task.delayDuration, DELAY_DURATION);
        assertEq(task.buddy, address(0));
        assertFalse(task.delayedRewardReleased);
    }

    function testCreateTaskWithBuddy() public {
        (uint256 taskId, bool success) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_SEND_BUDDY,
            0,
            buddy
        );

        assertTrue(success);
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.buddy, buddy);
        assertEq(task.choice, CHOICE_SEND_BUDDY);
    }

    function testCreateTaskUpdatesNextExpiringTask() public {
        uint256 shortDeadline = 1800; // 30 minutes
        uint256 longDeadline = 7200; // 2 hours

        // Create task with longer deadline first
        taskManager.createTask(
            "Long task",
            REWARD_AMOUNT,
            longDeadline,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Create task with shorter deadline
        taskManager.createTask(
            "Short task",
            REWARD_AMOUNT,
            shortDeadline,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // The shorter deadline task should be the next expiring
        assertEq(taskManager.nextExpiringTaskId(), 1);
        assertEq(taskManager.nextDeadline(), block.timestamp + shortDeadline);
    }

    function testCreateTaskRevertsWithEmptyDescription() public {
        vm.expectRevert(TaskManager.TaskManager__EmptyDescription.selector);
        taskManager.createTask("", REWARD_AMOUNT, DEADLINE_SECONDS, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0));
    }

    function testCreateTaskRevertsWithZeroReward() public {
        vm.expectRevert(TaskManager.TaskManager__RewardAmountMustBeGreaterThanZero.selector);
        taskManager.createTask(TASK_DESCRIPTION, 0, DEADLINE_SECONDS, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0));
    }

    function testCreateTaskRevertsWithInvalidPenaltyConfig() public {
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_SEND_BUDDY,
            DELAY_DURATION,
            address(0) // buddy cannot be zero address for choice 2
        );
    }

    function testOnlyOwnerCanCreateTask() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           TASK COMPLETION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteTask() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        vm.expectEmit(true, false, false, false);
        emit TaskCompleted(taskId);

        taskManager.completeTask(taskId);

        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.COMPLETED));
    }

    function testCompleteTaskRevertsIfAlreadyCompleted() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        taskManager.completeTask(taskId);

        vm.expectRevert(TaskManager.TaskManager__TaskAlreadyCompleted.selector);
        taskManager.completeTask(taskId);
    }

    function testCompleteTaskRevertsIfExpired() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);
        taskManager.expireTask(taskId);

        vm.expectRevert(TaskManager.TaskManager__TaskHasExpired.selector);
        taskManager.completeTask(taskId);
    }

    function testCompleteTaskRevertsIfCanceled() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        taskManager.cancelTask(taskId);

        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
        taskManager.completeTask(taskId);
    }

    function testOnlyOwnerCanCompleteTask() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        vm.prank(nonOwner);
        vm.expectRevert();
        taskManager.completeTask(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                           TASK CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCancelTask() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        vm.expectEmit(true, false, false, false);
        emit TaskCanceled(taskId);

        taskManager.cancelTask(taskId);

        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.CANCELED));
    }

    function testCancelTaskRevertsIfAlreadyCanceled() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        taskManager.cancelTask(taskId);

        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
        taskManager.cancelTask(taskId);
    }

    function testOnlyOwnerCanCancelTask() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        vm.prank(nonOwner);
        vm.expectRevert();
        taskManager.cancelTask(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                           TASK EXPIRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testExpireTask() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        vm.expectEmit(true, false, false, false);
        emit TaskExpired(taskId);

        taskManager.expireTask(taskId);

        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.EXPIRED));
    }

    function testExpireTaskRevertsIfNotYetExpired() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        vm.expectRevert(TaskManager.TaskManager__TaskNotYetExpired.selector);
        taskManager.expireTask(taskId);
    }

    function testExpireTaskRevertsIfAlreadyExpired() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline and expire
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);
        taskManager.expireTask(taskId);

        vm.expectRevert(TaskManager.TaskManager__TaskHasExpired.selector);
        taskManager.expireTask(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                           AUTOMATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCheckUpkeepReturnsFalseWhenNoExpiredTasks() public {
        taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function testCheckUpkeepReturnsTrueWhenTasksExpired() public {
        // Create multiple tasks
        taskManager.createTask("Task 1", REWARD_AMOUNT, 1800, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0)); // 30 min
        taskManager.createTask("Task 2", REWARD_AMOUNT, 3600, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0)); // 1 hour
        taskManager.createTask("Task 3", REWARD_AMOUNT, 7200, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0)); // 2 hours

        // Fast forward to expire first two tasks
        vm.warp(block.timestamp + 3601); // Just past 1 hour

        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        
        assertTrue(upkeepNeeded);
        assertTrue(performData.length > 0);

        (uint256[] memory expiredTaskIds, uint256 count) = abi.decode(performData, (uint256[], uint256));
        assertEq(count, 2);
        assertEq(expiredTaskIds[0], 0); // First task
        assertEq(expiredTaskIds[1], 1); // Second task
    }

    function testPerformUpkeep() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Get upkeep data
        (, bytes memory performData) = taskManager.checkUpkeep("");

        vm.expectEmit(true, false, false, false);
        emit TaskExpired(taskId);

        taskManager.performUpkeep(performData);

        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.EXPIRED));
    }

    /*//////////////////////////////////////////////////////////////
                         DELAYED PAYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testReleaseDelayedPayment() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline to expire task
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);
        taskManager.expireTask(taskId);

        // Fast forward past delay duration
        vm.warp(block.timestamp + DELAY_DURATION + 1);

        vm.expectEmit(true, true, false, false);
        emit TaskDelayedPaymentReleased(taskId, REWARD_AMOUNT);

        taskManager.releaseDelayedPayment(taskId);

        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertTrue(task.delayedRewardReleased);
    }

    function testReleaseDelayedPaymentRevertsIfNotExpired() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        vm.expectRevert(TaskManager.TaskManager__TaskNotYetExpired.selector);
        taskManager.releaseDelayedPayment(taskId);
    }

    function testReleaseDelayedPaymentRevertsIfDelayNotElapsed() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline but not past delay
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);
        taskManager.expireTask(taskId);

        vm.expectRevert(TaskManager.TaskManager__TaskNotYetExpired.selector);
        taskManager.releaseDelayedPayment(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetTask() public {
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        TaskManager.Task memory task = taskManager.getTask(taskId);
        
        assertEq(task.id, taskId);
        assertEq(task.description, TASK_DESCRIPTION);
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        assertTrue(task.valid);
    }

    function testGetTaskRevertsForInvalidId() public {
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        taskManager.getTask(999);
    }

    function testGetAllTasks() public {
        // Create multiple tasks
        taskManager.createTask("Task 1", 1 ether, DEADLINE_SECONDS, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0));
        taskManager.createTask("Task 2", 2 ether, DEADLINE_SECONDS, CHOICE_SEND_BUDDY, 0, buddy);
        
        TaskManager.Task[] memory tasks = taskManager.getAllTasks();
        
        assertEq(tasks.length, 2);
        assertEq(tasks[0].description, "Task 1");
        assertEq(tasks[1].description, "Task 2");
        assertEq(tasks[0].rewardAmount, 1 ether);
        assertEq(tasks[1].rewardAmount, 2 ether);
    }

    function testGetTotalTasks() public {
        assertEq(taskManager.getTotalTasks(), 0);
        
        taskManager.createTask(TASK_DESCRIPTION, REWARD_AMOUNT, DEADLINE_SECONDS, CHOICE_DELAYED_PAYMENT, DELAY_DURATION, address(0));
        assertEq(taskManager.getTotalTasks(), 1);
        
        taskManager.createTask("Another task", REWARD_AMOUNT, DEADLINE_SECONDS, CHOICE_SEND_BUDDY, 0, buddy);
        assertEq(taskManager.getTotalTasks(), 2);
    }

    function testIsValidTask() public {
        assertFalse(taskManager.isValidTask(0));
        
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );
        
        assertTrue(taskManager.isValidTask(taskId));
        assertFalse(taskManager.isValidTask(taskId + 1));
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzzCreateTask(
        string memory description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration
    ) public {
        // Bound inputs to valid ranges
        vm.assume(bytes(description).length > 0 && bytes(description).length < 1000);
        rewardAmount = bound(rewardAmount, 1, type(uint128).max);
        deadlineInSeconds = bound(deadlineInSeconds, 1, 365 days);
        choice = uint8(bound(choice, 1, 2));
        delayDuration = bound(delayDuration, 0, 30 days);

        address testBuddy = choice == 2 ? buddy : address(0);
        
        (uint256 taskId, bool success) = taskManager.createTask(
            description,
            rewardAmount,
            deadlineInSeconds,
            choice,
            delayDuration,
            testBuddy
        );

        assertTrue(success);
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.description, description);
        assertEq(task.rewardAmount, rewardAmount);
        assertEq(task.choice, choice);
        assertEq(task.delayDuration, delayDuration);
    }

    /*//////////////////////////////////////////////////////////////
                             INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteTaskFlow() public {
        // Create task
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Verify initial state
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.PENDING));

        // Complete task before deadline
        taskManager.completeTask(taskId);

        // Verify completion
        task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.COMPLETED));
    }

    function testExpiredTaskFlow() public {
        // Create task
        (uint256 taskId,) = taskManager.createTask(
            TASK_DESCRIPTION,
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            CHOICE_DELAYED_PAYMENT,
            DELAY_DURATION,
            address(0)
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Check upkeep detects expired task
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        assertTrue(upkeepNeeded);

        // Perform upkeep
        taskManager.performUpkeep(performData);

        // Verify expiration
        TaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.EXPIRED));

        // Fast forward past delay duration
        vm.warp(block.timestamp + DELAY_DURATION + 1);

        // Release delayed payment
        taskManager.releaseDelayedPayment(taskId);
        task = taskManager.getTask(taskId);
        assertTrue(task.delayedRewardReleased);
    }
}