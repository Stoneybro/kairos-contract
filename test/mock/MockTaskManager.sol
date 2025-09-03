// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ITaskManager} from "../../src/interface/ITaskManager.sol";
import {ISmartAccount} from "../../src/interface/ISmartAccount.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MockTaskManager is ITaskManager {
    mapping(address => mapping(uint256 => Task)) public s_tasks;
    mapping(address => uint256) public s_taskCounters;

    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy
    ) external override returns (uint256) {
        address account = msg.sender;
        uint256 taskId = s_taskCounters[account];
        s_tasks[account][taskId] = Task({
            id: taskId,
            description: description,
            rewardAmount: rewardAmount,
            deadline: block.timestamp + deadlineInSeconds,
            valid: true,
            status: TaskStatus.PENDING,
            choice: choice,
            delayDuration: delayDuration,
            buddy: buddy,
            delayedRewardReleased: false
        });
        s_taskCounters[account]++;
        return taskId;
    }

    function completeTask(uint256 taskId) external override {
        s_tasks[msg.sender][taskId].status = TaskStatus.COMPLETED;
    }

    function cancelTask(uint256 taskId) external override {
        s_tasks[msg.sender][taskId].status = TaskStatus.CANCELED;
    }

    function releaseDelayedPayment(uint256 taskId) external override {
        s_tasks[msg.sender][taskId].delayedRewardReleased = true;
    }

    function getTask(address account, uint256 taskId) external view override returns (Task memory) {
        return s_tasks[account][taskId];
    }

    function getTotalTasks(address account) external view override returns (uint256) {
        return s_taskCounters[account];
    }

    function getAllTasks(
        address account,
        uint256 cursor,
        uint256 pageSize
    ) external view override returns (Task[] memory tasks, uint256 nextCursor) {
        // This is a mock implementation. Returning empty for script simplicity.
        tasks = new Task[](0);
        nextCursor = 0;
        // A full implementation would paginate through the s_tasks mapping.
    }

    /**
     * @notice Test function to manually set a task as expired and trigger the callback.
     */
    function expireTask(address account, uint256 taskId) external {
        s_tasks[account][taskId].status = TaskStatus.EXPIRED;
        // Call the callback on the smart account to trigger penalty logic
        ISmartAccount(payable(account)).expiredTaskCallback(taskId);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(ITaskManager).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}