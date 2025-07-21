// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISmartAccount} from "./interface/ISmartAccount.sol";
import {ITaskManager} from "./interface/ITaskManager.sol";

contract TaskManager is ITaskManager, AutomationCompatibleInterface, ReentrancyGuard {
    struct TaskIdentifier {
        address account;
        uint256 taskId;
    }

    mapping(address => mapping(uint256 => Task)) private s_tasks;
    mapping(address => uint256) private s_taskCounters;

    // Pointers to the next task for Chainlink Automation
    uint256 public s_nextExpiringTaskId;
    uint256 public s_nextDeadline = type(uint256).max;
    address public s_nextExpiringTaskAccount;

    // Data structures for finding the next expiring task
    TaskIdentifier[] private s_pendingTasks;
    mapping(address => mapping(uint256 => uint256)) private s_pendingTaskIndex;

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event TaskExpiredCallFailure(uint256 indexed taskId);
    event TaskDelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);


    error TaskManager__TaskDoesntExist();
    error TaskManager__EmptyDescription();
    error TaskManager__RewardAmountMustBeGreaterThanZero();
    error TaskManager__InvalidPenaltyConfig();
    error TaskManager__TaskAlreadyCompleted();
    error TaskManager__TaskHasBeenCanceled();
    error TaskManager__TaskHasExpired();
    error TaskManager__TaskNotYetExpired();
    error TaskManager__InvalidChoice();


    constructor() {}

    modifier taskExist(address account, uint256 taskId) {
        if (taskId >= s_taskCounters[account]) {
            revert TaskManager__TaskDoesntExist();
        }
        _;
    }

    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy
    ) external override returns (uint256) {
        address account = msg.sender;
        if (bytes(description).length == 0) {
            revert TaskManager__EmptyDescription();
        }
        if (rewardAmount == 0) {
            revert TaskManager__RewardAmountMustBeGreaterThanZero();
        }
        if (choice == 2 && buddy == address(0)) {
            revert TaskManager__InvalidPenaltyConfig();
        }
        if (choice == 1 && delayDuration == 0) {
            revert TaskManager__InvalidPenaltyConfig();
        }
        if (choice > 2 || choice == 0) {
            revert TaskManager__InvalidChoice();
        }

        uint256 deadline = block.timestamp + deadlineInSeconds;
        uint256 newTaskId = s_taskCounters[account];

        s_tasks[account][newTaskId] = Task({
            id: newTaskId,
            description: description,
            rewardAmount: rewardAmount,
            deadline: deadline,
            valid: true,
            status: TaskStatus.PENDING,
            choice: choice,
            delayDuration: delayDuration,
            buddy: buddy,
            delayedRewardReleased: false
        });

        // Add to pending tasks list for upkeep
        uint256 pendingIndex = s_pendingTasks.length;
        s_pendingTasks.push(TaskIdentifier(account, newTaskId));
        s_pendingTaskIndex[account][newTaskId] = pendingIndex;

        if (deadline < s_nextDeadline) {
            s_nextExpiringTaskAccount = account;
            s_nextExpiringTaskId = newTaskId;
            s_nextDeadline = deadline;
        }

        emit TaskCreated(newTaskId, description, rewardAmount);
        s_taskCounters[account]++;
        return newTaskId;
    }

    function checkUpkeep(bytes calldata) public view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = (s_nextExpiringTaskAccount != address(0) && block.timestamp > s_nextDeadline);
        performData = abi.encode(s_nextExpiringTaskAccount, s_nextExpiringTaskId);
    }

    function performUpkeep(bytes calldata performData) external override {
        (address account, uint256 taskId) = abi.decode(performData, (address, uint256));

        if (account != s_nextExpiringTaskAccount || taskId != s_nextExpiringTaskId) {
            return;
        }

        Task storage task = s_tasks[account][taskId];

        if (block.timestamp > task.deadline && task.status == TaskStatus.PENDING) {
            task.status = TaskStatus.EXPIRED;
            emit TaskExpired(taskId);

            try ISmartAccount(account).expiredTaskCallback(taskId) {
                // Call was successful, no action needed.
            } catch {
                emit TaskExpiredCallFailure(taskId);
            }
            
            _removeTaskFromPendingList(account, taskId);
            _findNextExpiringTask();
        }
    }

    function _findNextExpiringTask() internal nonReentrant {
        uint256 minDeadline = type(uint256).max;
        address nextAccount;
        uint256 nextTaskId;

        // This loop can be gas-intensive if there are many pending tasks.
        // For a production system, consider limiting the number of pending tasks.
        for (uint i = 0; i < s_pendingTasks.length; i++) {
            TaskIdentifier memory identifier = s_pendingTasks[i];
            Task storage task = s_tasks[identifier.account][identifier.taskId];

            // The check for PENDING status is redundant if list is managed correctly,
            // but it's a good safeguard.
            if (task.status == TaskStatus.PENDING && task.deadline < minDeadline) {
                minDeadline = task.deadline;
                nextAccount = identifier.account;
                nextTaskId = identifier.taskId;
            }
        }

        s_nextDeadline = minDeadline;
        s_nextExpiringTaskAccount = nextAccount;
        s_nextExpiringTaskId = nextTaskId;
    }

    function completeTask(uint256 taskId) external override taskExist(msg.sender, taskId) {
        Task storage task = s_tasks[msg.sender][taskId];
        if (task.status == TaskStatus.COMPLETED) {
            revert TaskManager__TaskAlreadyCompleted();
        }
        if (task.status != TaskStatus.PENDING) {
            revert TaskManager__TaskHasBeenCanceled();
        }
        task.status = TaskStatus.COMPLETED;
        emit TaskCompleted(taskId);

        if (msg.sender == s_nextExpiringTaskAccount && taskId == s_nextExpiringTaskId) {
            _removeTaskFromPendingList(msg.sender, taskId);
            _findNextExpiringTask();
        }
    }

    function cancelTask(uint256 taskId) external override taskExist(msg.sender, taskId) {
        Task storage task = s_tasks[msg.sender][taskId];
        if (task.status == TaskStatus.CANCELED) {
            revert TaskManager__TaskHasBeenCanceled();
        }
        if (task.status != TaskStatus.PENDING) {
            revert TaskManager__TaskAlreadyCompleted();
        }
        task.status = TaskStatus.CANCELED;
        emit TaskCanceled(taskId);

        if (msg.sender == s_nextExpiringTaskAccount && taskId == s_nextExpiringTaskId) {
            _removeTaskFromPendingList(msg.sender, taskId);
            _findNextExpiringTask();
        }
    }

    function _removeTaskFromPendingList(address account, uint256 taskId) internal {
        uint256 indexToRemove = s_pendingTaskIndex[account][taskId];
        uint256 lastIndex = s_pendingTasks.length - 1;

        // We use the swap-and-pop trick for O(1) removal
        if (indexToRemove != lastIndex) {
            TaskIdentifier memory lastIdentifier = s_pendingTasks[lastIndex];
            s_pendingTasks[indexToRemove] = lastIdentifier;

            // Update the index of the element that was moved
            s_pendingTaskIndex[lastIdentifier.account][lastIdentifier.taskId] = indexToRemove;
        }

        // Remove the last element
        s_pendingTasks.pop();

        // Clean up the index mapping for the removed task
        delete s_pendingTaskIndex[account][taskId];
    }
    
    function releaseDelayedPayment(uint256 taskId) external override taskExist(msg.sender, taskId) {
        Task storage task = s_tasks[msg.sender][taskId];
        if (task.status != TaskStatus.EXPIRED) {
            revert TaskManager__TaskNotYetExpired();
        }
        if (task.choice != 1) { // PENALTY_DELAYEDPAYMENT
            revert TaskManager__InvalidPenaltyConfig();
        }
        task.delayedRewardReleased = true;
        emit TaskDelayedPaymentReleased(taskId, task.rewardAmount);
    }

    function getTask(address account, uint256 taskId) external view override taskExist(account,taskId) returns (Task memory) {
        return s_tasks[account][taskId];
    }
    
    function getAllTasks(address account, uint256 cursor, uint256 pageSize) external view override returns (Task[] memory tasks, uint256 nextCursor) {
        uint256 taskCount = s_taskCounters[account];
        if (cursor >= taskCount) {
            return (new Task[](0), taskCount);
        }

        uint256 end = cursor + pageSize;
        if (end > taskCount) {
            end = taskCount;
        }

        uint256 length = end - cursor;
        tasks = new Task[](length);
        for (uint256 i = 0; i < length; i++) {
            tasks[i] = s_tasks[account][cursor + i];
        }
        return (tasks, end);
    }

    function getTotalTasks(address account) external view override returns (uint256) {
        return s_taskCounters[account];
    }

    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        return
            interfaceId == type(ITaskManager).interfaceId ||
            interfaceId == type(AutomationCompatibleInterface).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
