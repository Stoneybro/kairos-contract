// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {TaskManager} from "src/TaskManager.sol";
import {ITaskManager} from "src/interface/ITaskManager.sol";
import {ISmartAccount} from "src/interface/ISmartAccount.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MockSmartAccount is ISmartAccount {
    bool public shouldRevert;
    uint256 public lastExpiredTaskId;

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function expiredTaskCallback(uint256 taskId) external override {
        if (shouldRevert) {
            revert("Mock revert");
        }
        lastExpiredTaskId = taskId;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ISmartAccount).interfaceId;
    }
}

contract TaskManagerTest is Test {
    TaskManager public taskManager;
    MockSmartAccount public mockAccount;
    address public user1;
    address public user2;
    address public buddy;

    uint8 constant PENALTY_DELAYEDPAYMENT = 1;
    uint8 constant PENALTY_SENDBUDDY = 2;

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event TaskExpiredCallFailure(uint256 indexed taskId);
    event TaskDelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);

    function setUp() public {
        taskManager = new TaskManager();
        mockAccount = new MockSmartAccount();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        buddy = makeAddr("buddy");
    }

    modifier prank(address account) {
        vm.prank(account);
        _;
    }

    function testCreateTask_Success() public prank(user1) {
        string memory description = "Complete daily workout";
        uint256 rewardAmount = 100 ether;
        uint256 deadlineInSeconds = 3600; // 1 hour
        uint8 choice = PENALTY_DELAYEDPAYMENT;
        uint256 delayDuration = 86400; // 24 hours

        vm.expectEmit(true, false, false, true);
        emit TaskCreated(0, description, rewardAmount);

        uint256 taskId =
            taskManager.createTask(description, rewardAmount, deadlineInSeconds, choice, delayDuration, address(0));

        assertEq(taskId, 0);

        ITaskManager.Task memory task = taskManager.getTask(user1, taskId);
        assertEq(task.id, taskId);
        assertEq(task.description, description);
        assertEq(task.rewardAmount, rewardAmount);
        assertEq(task.deadline, block.timestamp + deadlineInSeconds);
        assertTrue(task.valid);
        assertEq(uint256(task.status), uint256(ITaskManager.TaskStatus.PENDING));
        assertEq(task.choice, choice);
        assertEq(task.delayDuration, delayDuration);
        assertEq(task.buddy, address(0));
        assertFalse(task.delayedRewardReleased);
    }

    function testCreateTask_WithBuddy() public prank(user1) {
        uint256 taskId = taskManager.createTask("Learn Solidity", 50 ether, 7200, PENALTY_SENDBUDDY, 0, buddy);

        ITaskManager.Task memory task = taskManager.getTask(user1, taskId);
        assertEq(task.buddy, buddy);
        assertEq(task.choice, PENALTY_SENDBUDDY);
    }

    function testCreateTask_RevertEmptyDescription() public prank(user1) {
        vm.expectRevert(TaskManager.TaskManager__EmptyDescription.selector);
        taskManager.createTask("", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
    }

    function testCreateTask_RevertZeroReward() public prank(user1) {
        vm.expectRevert(TaskManager.TaskManager__RewardAmountMustBeGreaterThanZero.selector);
        taskManager.createTask("Test task", 0, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
    }

    function testCreateTask_RevertInvalidChoice() public prank(user1) {
        vm.expectRevert(TaskManager.TaskManager__InvalidChoice.selector);
        taskManager.createTask("Test task", 100 ether, 3600, 0, 86400, address(0));

        vm.expectRevert(TaskManager.TaskManager__InvalidChoice.selector);
        taskManager.createTask("Test task", 100 ether, 3600, 3, 86400, address(0));
    }

    function testCreateTask_RevertInvalidPenaltyConfig() public prank(user1) {
        // Test buddy penalty without buddy address
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        taskManager.createTask("Test task", 100 ether, 3600, PENALTY_SENDBUDDY, 0, address(0));

        // Test delayed payment without delay duration
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 0, address(0));
    }

    function testCompleteTask_Success() public {
        vm.startPrank(user1);
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        vm.expectEmit(true, false, false, false);
        emit TaskCompleted(taskId);
        taskManager.completeTask(taskId);
        ITaskManager.Task memory task = taskManager.getTask(user1, taskId);
        assertEq(uint256(task.status), uint256(ITaskManager.TaskStatus.COMPLETED));
        vm.stopPrank();
    }

    function testCompleteTask_RevertTaskDoesntExist() public prank(user1) {
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        taskManager.completeTask(999);
    }

    function testCompleteTask_RevertAlreadyCompleted() public {
        vm.startPrank(user1);
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        taskManager.completeTask(taskId);
        vm.expectRevert(TaskManager.TaskManager__TaskAlreadyCompleted.selector);
        taskManager.completeTask(taskId);
        vm.stopPrank();
    }

    function testCompleteTask_RevertTaskCanceled() public {
        vm.startPrank(user1);
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        taskManager.cancelTask(taskId);
        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
        taskManager.completeTask(taskId);
        vm.stopPrank();
    }

    function testCancelTask_Success() public {
        vm.startPrank(user1);
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        vm.expectEmit(true, false, false, false);
        emit TaskCanceled(taskId);
        taskManager.cancelTask(taskId);
        ITaskManager.Task memory task = taskManager.getTask(user1, taskId);
        assertEq(uint256(task.status), uint256(ITaskManager.TaskStatus.CANCELED));
        vm.stopPrank();
    }

    function testCancelTask_RevertAlreadyCanceled() public {
        vm.startPrank(user1);
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        taskManager.cancelTask(taskId);
        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
        taskManager.cancelTask(taskId);
        vm.stopPrank();
    }

    function testCancelTask_RevertAlreadyCompleted() public {
        vm.startPrank(user1);
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        taskManager.completeTask(taskId);
        vm.expectRevert(TaskManager.TaskManager__TaskAlreadyCompleted.selector);
        taskManager.cancelTask(taskId);
        vm.stopPrank();
    }

    function testCheckUpkeep_NoUpkeepNeeded() public {
        (bool upkeepNeeded,) = taskManager.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function testCheckUpkeep_UpkeepNeeded() public {
        // Create task with very short deadline
        vm.prank(address(mockAccount));
        taskManager.createTask(
            "Test task",
            100 ether,
            1, // 1 second deadline
            PENALTY_DELAYEDPAYMENT,
            86400,
            address(0)
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + 2);

        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        assertTrue(upkeepNeeded);

        (address account, uint256 taskId) = abi.decode(performData, (address, uint256));
        assertEq(account, address(mockAccount));
        assertEq(taskId, 0);
    }

    function testPerformUpkeep_TaskExpired() public {
        // Create task with short deadline
        vm.prank(address(mockAccount));
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 1, PENALTY_DELAYEDPAYMENT, 86400, address(0));

        // Fast forward past deadline
        vm.warp(block.timestamp + 2);

        bytes memory performData = abi.encode(address(mockAccount), taskId);

        vm.expectEmit(true, false, false, false);
        emit TaskExpired(taskId);

        taskManager.performUpkeep(performData);

        ITaskManager.Task memory task = taskManager.getTask(address(mockAccount), taskId);
        assertEq(uint256(task.status), uint256(ITaskManager.TaskStatus.EXPIRED));
        assertEq(mockAccount.lastExpiredTaskId(), taskId);
    }

    function testPerformUpkeep_CallbackFails() public {
        // Set mock to revert
        mockAccount.setRevert(true);

        vm.prank(address(mockAccount));
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 1, PENALTY_DELAYEDPAYMENT, 86400, address(0));

        vm.warp(block.timestamp + 2);

        bytes memory performData = abi.encode(address(mockAccount), taskId);

        vm.expectEmit(true, false, false, false);
        emit TaskExpiredCallFailure(taskId);

        taskManager.performUpkeep(performData);

        ITaskManager.Task memory task = taskManager.getTask(address(mockAccount), taskId);
        assertEq(uint256(task.status), uint256(ITaskManager.TaskStatus.EXPIRED));
    }

    function testReleaseDelayedPayment_Success() public {
        vm.prank(address(mockAccount));
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 1, PENALTY_DELAYEDPAYMENT, 86400, address(0));

        // Expire the task
        vm.warp(block.timestamp + 2);
        bytes memory performData = abi.encode(address(mockAccount), taskId);
        taskManager.performUpkeep(performData);

        vm.expectEmit(true, true, false, false);
        emit TaskDelayedPaymentReleased(taskId, 100 ether);

        vm.prank(address(mockAccount));
        taskManager.releaseDelayedPayment(taskId);

        ITaskManager.Task memory task = taskManager.getTask(address(mockAccount), taskId);
        assertTrue(task.delayedRewardReleased);
    }

    function testReleaseDelayedPayment_RevertNotExpired() public {
        vm.prank(address(mockAccount));
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));

        vm.prank(address(mockAccount));
        vm.expectRevert(TaskManager.TaskManager__TaskNotYetExpired.selector);
        taskManager.releaseDelayedPayment(taskId);
    }

    function testReleaseDelayedPayment_RevertWrongPenaltyType() public {
        vm.prank(address(mockAccount));
        uint256 taskId = taskManager.createTask("Test task", 100 ether, 1, PENALTY_SENDBUDDY, 0, buddy);

        // Expire the task
        vm.warp(block.timestamp + 2);
        bytes memory performData = abi.encode(address(mockAccount), taskId);
        taskManager.performUpkeep(performData);

        vm.prank(address(mockAccount));
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        taskManager.releaseDelayedPayment(taskId);
    }

    function testGetTotalTasks() public {
        assertEq(taskManager.getTotalTasks(user1), 0);

        vm.prank(user1);
        taskManager.createTask("Task 1", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        assertEq(taskManager.getTotalTasks(user1), 1);

        vm.prank(user1);
        taskManager.createTask("Task 2", 200 ether, 7200, PENALTY_SENDBUDDY, 0, buddy);
        assertEq(taskManager.getTotalTasks(user1), 2);
    }

    function testGetAllTasks() public {
        // Create multiple tasks
        vm.startPrank(user1);
        taskManager.createTask("Task 1", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));
        taskManager.createTask("Task 2", 200 ether, 7200, PENALTY_SENDBUDDY, 0, buddy);
        taskManager.createTask("Task 3", 300 ether, 10800, PENALTY_DELAYEDPAYMENT, 43200, address(0));
        vm.stopPrank();

        // Test pagination
        (ITaskManager.Task[] memory tasks, uint256 nextCursor) = taskManager.getAllTasks(user1, 0, 2);
        assertEq(tasks.length, 2);
        assertEq(tasks[0].description, "Task 1");
        assertEq(tasks[1].description, "Task 2");
        assertEq(nextCursor, 2);

        // Get remaining tasks
        (tasks, nextCursor) = taskManager.getAllTasks(user1, 2, 2);
        assertEq(tasks.length, 1);
        assertEq(tasks[0].description, "Task 3");
        assertEq(nextCursor, 3);

        // Test cursor beyond available tasks
        (tasks, nextCursor) = taskManager.getAllTasks(user1, 5, 2);
        assertEq(tasks.length, 0);
        assertEq(nextCursor, 3);
    }

    function testMultipleUsers() public {
        // User1 creates tasks
        vm.prank(user1);
        uint256 user1TaskId =
            taskManager.createTask("User1 Task", 100 ether, 3600, PENALTY_DELAYEDPAYMENT, 86400, address(0));

        // User2 creates tasks
        vm.prank(user2);
        uint256 user2TaskId = taskManager.createTask("User2 Task", 200 ether, 7200, PENALTY_SENDBUDDY, 0, buddy);

        // Verify tasks are isolated per user
        assertEq(user1TaskId, 0);
        assertEq(user2TaskId, 0);

        ITaskManager.Task memory user1Task = taskManager.getTask(user1, user1TaskId);
        ITaskManager.Task memory user2Task = taskManager.getTask(user2, user2TaskId);

        assertEq(user1Task.description, "User1 Task");
        assertEq(user2Task.description, "User2 Task");
        assertEq(user1Task.rewardAmount, 100 ether);
        assertEq(user2Task.rewardAmount, 200 ether);
    }

    function testNextExpiringTaskTracking() public {
        // Initially no expiring tasks
        assertEq(taskManager.s_nextExpiringTaskAccount(), address(0));
        assertEq(taskManager.s_nextDeadline(), type(uint256).max);

        // Create task with longer deadline
        vm.prank(user1);
        taskManager.createTask("Long task", 100 ether, 7200, PENALTY_DELAYEDPAYMENT, 86400, address(0));

        assertEq(taskManager.s_nextExpiringTaskAccount(), user1);
        assertEq(taskManager.s_nextExpiringTaskId(), 0);

        // Create task with shorter deadline
        vm.prank(user2);
        taskManager.createTask("Short task", 200 ether, 3600, PENALTY_SENDBUDDY, 0, buddy);

        // Should update to the shorter deadline task
        assertEq(taskManager.s_nextExpiringTaskAccount(), user2);
        assertEq(taskManager.s_nextExpiringTaskId(), 0);
    }

    function testSupportsInterface() public {
        assertTrue(taskManager.supportsInterface(type(ITaskManager).interfaceId));
        assertTrue(taskManager.supportsInterface(type(IERC165).interfaceId));
        assertFalse(taskManager.supportsInterface(bytes4(0x12345678)));
    }

    function testFuzz_CreateTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice
    ) public {
        // Bound inputs to valid ranges
        vm.assume(bytes(description).length > 0);
        vm.assume(rewardAmount > 0);
        vm.assume(deadlineInSeconds > 0 && deadlineInSeconds < 365 days);
        choice = uint8(bound(choice, 1, 2));

        vm.prank(user1);
        if (choice == PENALTY_DELAYEDPAYMENT) {
            uint256 taskId =
                taskManager.createTask(description, rewardAmount, deadlineInSeconds, choice, 86400, address(0));
            ITaskManager.Task memory task = taskManager.getTask(user1, taskId);
            assertEq(task.description, description);
            assertEq(task.rewardAmount, rewardAmount);
            assertEq(task.choice, choice);
        } else if (choice == PENALTY_SENDBUDDY) {
            uint256 taskId = taskManager.createTask(description, rewardAmount, deadlineInSeconds, choice, 0, buddy);
            ITaskManager.Task memory task = taskManager.getTask(user1, taskId);
            assertEq(task.description, description);
            assertEq(task.rewardAmount, rewardAmount);
            assertEq(task.choice, choice);
            assertEq(task.buddy, buddy);
        }
    }
}
