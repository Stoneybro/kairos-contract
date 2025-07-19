// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MockTaskManager {
    enum TaskStatus {
        PENDING,
        COMPLETED,
        CANCELED,
        EXPIRED
    }

    struct Task {
        uint256 taskId;
        string description;
        uint256 rewardAmount;
        uint256 deadline;
        TaskStatus status;
        bool valid;
        uint8 choice;
        uint256 delayDuration;
    }

    mapping(uint256 => Task) public tasks;
    uint256 public taskCounter;
    bool public forceCreateFail;
    bool public forcePaymentFail;

    modifier taskExists(uint256 taskId) {
        require(tasks[taskId].valid, "Task does not exist");
        _;
    }

    function createTask(string calldata description, uint256 rewardAmount, uint256 durationInSeconds, uint8 choice,uint256 delayDuration)
        external
        returns (uint256, bool)
    {
        if (forceCreateFail) {
            return (0, false);
        }

        tasks[taskCounter] = Task({
            taskId: taskCounter,
            description: description,
            rewardAmount: rewardAmount,
            deadline: block.timestamp + durationInSeconds,
            status: TaskStatus.PENDING,
            valid: true,
            choice: choice,
            delayDuration:delayDuration
        });
        taskCounter++;
        return (taskCounter - 1, true);
    }

    function completeTask(uint256 taskId) external taskExists(taskId) {
        Task storage task = tasks[taskId];

        require(task.status == TaskStatus.PENDING, "Task not pending");

        task.status = TaskStatus.COMPLETED;
    }

    function cancelTask(uint256 taskId) external taskExists(taskId) {
        Task storage task = tasks[taskId];

        require(task.status == TaskStatus.PENDING, "Task not pending");

        task.status = TaskStatus.CANCELED;
    }

    function expireTask(uint256 taskId) external taskExists(taskId) {
        Task storage task = tasks[taskId];

        require(block.timestamp > task.deadline, "Task not yet expired");
        require(task.status == TaskStatus.PENDING, "Task not pending");

        task.status = TaskStatus.EXPIRED;
    }

    function getTask(uint256 taskId) external view returns (Task memory) {
        return tasks[taskId];
    }

    // Force failure for createTask
    function setForceCreateFail(bool _force) external {
        forceCreateFail = _force;
    }

    // Force failure for payment scenarios
    function setForcePaymentFail(bool _force) external {
        forcePaymentFail = _force;
    }
}
