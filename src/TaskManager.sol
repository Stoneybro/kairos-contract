// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TaskManager is AutomationCompatibleInterface, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    enum TaskStatus {
        PENDING,
        COMPLETED,
        CANCELED,
        EXPIRED
    }

    struct Task {
        uint256 id;
        string description;
        uint256 rewardAmount;
        uint256 deadline;
        bool valid;
        TaskStatus status;
        uint8 choice;
        uint256 delayDuration;
        address buddy;
        bool delayedRewardReleased;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => Task) private s_tasks;
    uint256 private s_taskId;
    uint256 public nextExpiringTaskId;
    uint256 public nextDeadline = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event TaskExpiredCallFailure(uint256 indexed taskId);
    event TaskDelayedPaymentReleased(uint256 indexed taskId,uint256 indexed rewardAmount);


    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error TaskManager__OnlyOwnerCanCallThisFunction();
    error TaskManager__TaskRewardPaymentFailed();
    error TaskManager__TaskAlreadyCompleted();
    error TaskManager__AddMoreFunds();
    error TaskManager__TaskHasBeenCanceled();
    error TaskManager__TaskDoesntExist();
    error TaskManager__TaskHasExpired();
    error TaskManager__TaskNotYetExpired();
    error TaskManager__ExpiredTaskCallBackFailed();
    error TaskManager__ReleaseDelayedPaymentFailed();
    error TaskManager__EmptyDescription();
    error TaskManager__RewardAmountMustBeGreaterThanZero();
    error TaskManager__InvalidDeadline();
    error TaskManager__InvalidPenaltyConfig();

    /*CONSTRUCTOR*/
    constructor(address owner) Ownable(owner) {}

    /*MODIFIERS*/
    modifier taskExist(uint256 taskId) {
        if (taskId >= s_taskId) {
            revert TaskManager__TaskDoesntExist();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy
    ) external onlyOwner returns (uint256, bool) {
        if (bytes(description).length == 0) {
            revert TaskManager__EmptyDescription();
        }
        if (rewardAmount == 0) {
            revert TaskManager__RewardAmountMustBeGreaterThanZero();
        }
        if (choice == 2 && buddy == address(0)) {
            revert TaskManager__InvalidPenaltyConfig();
        }
        uint256 deadline = block.timestamp + deadlineInSeconds;

        s_tasks[s_taskId] = Task({
            id: s_taskId,
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

        if (deadline < nextDeadline) {
            nextExpiringTaskId = s_taskId;
            nextDeadline = deadline;
        }

        emit TaskCreated(s_taskId, description, rewardAmount);
        uint256 currentTaskId = s_taskId;
        s_taskId++;
        return (currentTaskId, true);
    }

    function checkUpkeep(bytes calldata) public view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256[] memory expiredTaskIds = new uint256[](s_taskId);
        uint256 count = 0;

        for (uint256 i = 0; i < s_taskId; i++) {
            Task storage task = s_tasks[i];
            if (task.valid && task.status == TaskStatus.PENDING && block.timestamp > task.deadline) {
                expiredTaskIds[count] = i;
                count++;
            }
        }
        upkeepNeeded = count > 0;
        if (upkeepNeeded) {
           
            uint256[] memory validExpiredTaskIds = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                validExpiredTaskIds[i] = expiredTaskIds[i];
            }
            performData = abi.encode(validExpiredTaskIds, count);
        } else {
            upkeepNeeded = false;
            performData = "";
        }
    }

    function performUpkeep(bytes calldata performData) external override {
        (uint256[] memory expiredTaskIds, uint256 count) = abi.decode(performData, (uint256[], uint256));

        for (uint256 i = 0; i < count; i++) {
            uint256 taskId = expiredTaskIds[i];
            Task storage task = s_tasks[taskId];

            if (task.valid && task.status == TaskStatus.PENDING && block.timestamp > task.deadline) {
                s_tasks[taskId].status = TaskStatus.EXPIRED;

                emit TaskExpired(taskId);

                (bool success,) = payable(owner()).call(abi.encodeWithSignature("expiredTaskCallback(uint256)", taskId));

                if (!success) {
                    emit TaskExpiredCallFailure(taskId);
                }
            }
        }

        _updateNextExpiringTask();
    }

    function expireTask(uint256 taskId) external onlyOwner taskExist(taskId) {
        Task storage task = s_tasks[taskId];

        if (!task.valid) {
            revert TaskManager__TaskDoesntExist();
        }
        if (block.timestamp <= task.deadline) {
            revert TaskManager__TaskNotYetExpired();
        }
        if (task.status == TaskStatus.EXPIRED) {
            revert TaskManager__TaskHasExpired();
        }
        if (task.status != TaskStatus.PENDING) {
            revert TaskManager__TaskHasBeenCanceled();
        }

        s_tasks[taskId].status = TaskStatus.EXPIRED;
        if (taskId == nextExpiringTaskId) {
            _updateNextExpiringTask();
        }

        emit TaskExpired(taskId);
    }

    function completeTask(uint256 taskId) external taskExist(taskId) onlyOwner {
        Task storage task = s_tasks[taskId];

        if (!task.valid) {
            revert TaskManager__TaskDoesntExist();
        }
        if (task.status == TaskStatus.EXPIRED) {
            revert TaskManager__TaskHasExpired();
        }
        if (task.status == TaskStatus.COMPLETED) {
            revert TaskManager__TaskAlreadyCompleted();
        }
        if (task.status == TaskStatus.CANCELED) {
            revert TaskManager__TaskHasBeenCanceled();
        }

        s_tasks[taskId].status = TaskStatus.COMPLETED;
        emit TaskCompleted(taskId);

        if (taskId == nextExpiringTaskId) {
            _updateNextExpiringTask();
        }
    }

    function cancelTask(uint256 taskId) external taskExist(taskId) onlyOwner {
        Task storage task = s_tasks[taskId];

        if (!task.valid) {
            revert TaskManager__TaskDoesntExist();
        }
        if (task.status == TaskStatus.COMPLETED) {
            revert TaskManager__TaskAlreadyCompleted();
        }
        if (task.status == TaskStatus.CANCELED) {
            revert TaskManager__TaskHasBeenCanceled();
        }
        if (task.status == TaskStatus.EXPIRED) {
            revert TaskManager__TaskHasExpired();
        }
        s_tasks[taskId].status = TaskStatus.CANCELED;
        if (taskId == nextExpiringTaskId) {
            _updateNextExpiringTask();
        }

        emit TaskCanceled(taskId);
    }

    function releaseDelayedPayment(uint256 taskId) external taskExist(taskId) onlyOwner {
        Task storage task = s_tasks[taskId];
        if (!task.valid) {
            revert TaskManager__TaskDoesntExist();
        }
        if (block.timestamp <= task.deadline+task.delayDuration) {
            revert TaskManager__TaskNotYetExpired();
        }
        if (task.status!=TaskStatus.EXPIRED) {
            revert TaskManager__TaskNotYetExpired();
        }
        if (task.choice!=1) {
            revert TaskManager__InvalidPenaltyConfig();
        }
        task.delayedRewardReleased=true;
        emit TaskDelayedPaymentReleased(taskId,task.rewardAmount);
    }

    function _updateNextExpiringTask() internal nonReentrant {
        uint256 soonestDeadline = type(uint256).max;
        uint256 soonestTaskId = 0;
        bool foundPendingTask = false;

        for (uint256 i = 0; i < s_taskId; i++) {
            Task storage task = s_tasks[i];
            if (task.valid && task.status == TaskStatus.PENDING && task.deadline < soonestDeadline) {
                soonestDeadline = task.deadline;
                soonestTaskId = i;
                foundPendingTask = true;
            }
        }

        if (foundPendingTask) {
            nextExpiringTaskId = soonestTaskId;
            nextDeadline = soonestDeadline;
        } else {
            nextExpiringTaskId = 0;
            nextDeadline = type(uint256).max;
        }
    }

    function getTask(uint256 taskId) external view taskExist(taskId) returns (Task memory) {
        Task memory task = s_tasks[taskId];
        if (!task.valid) {
            revert TaskManager__TaskDoesntExist();
        }
        return task;
    }

    function getAllTasks() external view returns (Task[] memory) {
        Task[] memory tasks = new Task[](s_taskId);
        for (uint256 i = 0; i < s_taskId; i++) {
            tasks[i] = s_tasks[i];
        }
        return tasks;
    }

    function getTotalTasks() external view returns (uint256) {
        return s_taskId;
    }

    function isValidTask(uint256 taskId) external view returns (bool) {
        if (taskId >= s_taskId) {
            return false;
        }
        return s_tasks[taskId].valid;
    }
}


