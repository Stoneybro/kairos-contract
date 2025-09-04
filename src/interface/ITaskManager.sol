// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ITaskManager is IERC165 {
    enum TaskStatus {
        PENDING,
        COMPLETED,
        CANCELED,
        EXPIRED
    }

    enum VerificationMethod {
        MANUAL, 
        PARTNER,
        AI 
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
        VerificationMethod verificationMethod;
    }



    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 VerificationMethod
    ) external returns (uint256);

    function completeTask(uint256 taskId) external;
    function cancelTask(uint256 taskId) external;
    function releaseDelayedPayment(uint256 taskId) external;
    function getTask(address account, uint256 taskId) external view returns (Task memory);
    function getTasksByStatus(address account, TaskStatus status, uint256 start, uint256 limit)
        external
        view
        returns (Task[] memory);
    function getTaskCountsByStatus(address account) external view returns (uint256[] memory);
    function getTotalTasks(address account) external view returns (uint256);
}
