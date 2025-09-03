// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ITaskManager is IERC165 {
    enum TaskStatus { PENDING, COMPLETED, CANCELED, EXPIRED }

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

    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy
    ) external returns (uint256);

    function completeTask(uint256 taskId) external;
    function cancelTask(uint256 taskId) external;
    function releaseDelayedPayment(uint256 taskId) external;
    function getTask(address account, uint256 taskId) external view returns (Task memory);
    function getAllTasks(address account) external view returns (Task[] memory tasks);
    function getTotalTasks(address account) external view returns (uint256);
}