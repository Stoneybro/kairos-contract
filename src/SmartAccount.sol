// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IAccount} from "lib/account-abstraction/contracts/interfaces/IAccount.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PackedUserOperation} from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "lib/account-abstraction/contracts/core/Helpers.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {TaskManager} from "./TaskManager.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Account model for users.
 * @author Livingstone zion
 * @notice This is the initial account model deployed by the Account Factory
 */
contract SmartAccount is Initializable, IAccount, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    address public s_owner;
    TaskManager public taskManager;
    IEntryPoint private i_entryPoint;
    uint256 public s_totalCommittedReward;
    uint8 constant PENALTY_DELAYEDPAYMENT = 1;
    uint8 constant PENALTY_SENDBUDDY = 2;
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event DurationPenaltyApplied(uint256 indexed taskId, uint256 indexed penaltyDuration);
    event DelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);
    event PenaltyFundsReleasedToBuddy(uint256 indexed taskId, uint256 indexed rewardAmount, address indexed buddy);
    event Transferred(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SmartAccount__OnlyOwnerCanCall();
    error SmartAccount__NotFromEntryPoint();
    error SmartAccount__ExecutionFailed(bytes result);
    error SmartAccount__TaskManagerAlreadyDeployed();
    error SmartAccount__AddMoreFunds();
    error SmartAccount__TaskCreationFailed();
    error SmartAccount__TaskRewardPaymentFailed();
    error SmartAccount__OnlyTaskManagerCanCall();
    error SmartAccount__PenaltyDurationNotElapsed();
    error SmartAccount__PenaltyTypeMismatch();
    error SmartAccount__PayPrefundFailed();
    error SmartAccount__UnlinkCurrentTaskManager();
    error SmartAccount__PickAPenalty();
    error SmartAccount__InvalidPenaltyChoice();
    error SmartAccount__TaskManagerNotLinked();
    error SmartAccount__NoTaskManagerLinked();
    error SmartAccount__CannotWithdrawCommittedRewards();
    error SmartAccount__TransferFailed();
    error SmartAccount__TaskNotExpired();
    error SmartAccount__InsufficientCommittedReward();
    error SmartAccount__PaymentAlreadyReleased();
    error SmartAccount__TaskAlreadyCompleted();
    error SmartAccount__CannotTransferZero();
    error SmartAccount__InvalidPenaltyConfig();
    error SmartAccount__RewardCannotBeZero();
    error SmartAccount__TaskAlreadyCanceled();
    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner, address entryPoint, TaskManager _taskManager) external initializer {
        s_owner = owner;
        i_entryPoint = IEntryPoint(entryPoint);
        taskManager = _taskManager;
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier requireFromEntryPoint() {
        if (msg.sender != address(i_entryPoint)) {
            revert SmartAccount__NotFromEntryPoint();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != s_owner) {
            revert SmartAccount__OnlyOwnerCanCall();
        }
        _;
    }

    modifier contractFundedForTasks(uint256 rewardAmount) {
        if (address(this).balance < s_totalCommittedReward + rewardAmount) {
            revert SmartAccount__AddMoreFunds();
        }
        _;
    }

    modifier taskManagerLinked() {
        if (address(taskManager) == address(0)) {
            revert SmartAccount__NoTaskManagerLinked();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           ACCOUNT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {}

    function execute(address dest, uint256 value, bytes calldata functionData)
        external
        requireFromEntryPoint
        nonReentrant
    {
        (bool success, bytes memory result) = dest.call{value: value}(functionData);
        if (!success) {
            revert SmartAccount__ExecutionFailed(result);
        }
    }

    function transfer(address destination, uint256 value) external nonReentrant onlyOwner {
        if (value == 0) {
            revert SmartAccount__CannotTransferZero();
        }
        if (value > (address(this).balance - s_totalCommittedReward)) {
            revert SmartAccount__CannotWithdrawCommittedRewards();
        }
        (bool success,) = destination.call{value: value}("");
        if (!success) {
            revert SmartAccount__TransferFailed();
        }
        emit Transferred(destination, value);
    }

    /*//////////////////////////////////////////////////////////////
                           ENTRY POINT SECTION
    //////////////////////////////////////////////////////////////*/
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        requireFromEntryPoint
        returns (uint256 validationData)
    {
        validationData = _validateSignature(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        returns (uint256 validationData)
    {
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address signer = ECDSA.recover(ethSignedMessageHash, userOp.signature);
        if (signer != s_owner) {
            return SIG_VALIDATION_FAILED;
        } else {
            return SIG_VALIDATION_SUCCESS;
        }
    }

    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(address(i_entryPoint)).call{value: missingAccountFunds}("");
            if (!success) {
                revert SmartAccount__PayPrefundFailed();
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          TASK MANAGER SECTION
    //////////////////////////////////////////////////////////////*/

    function getTaskManagerAddress() external view returns (address) {
        return address(taskManager);
    }

    /*//////////////////////////////////////////////////////////////
                             TASK ACTIONS
    //////////////////////////////////////////////////////////////*/
    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        address buddy,
        uint256 delayDuration
    ) external onlyOwner taskManagerLinked contractFundedForTasks(rewardAmount) {
        if (choice == 0) {
            revert SmartAccount__PickAPenalty();
        }
        if (choice > 2) {
            revert SmartAccount__InvalidPenaltyChoice();
        }
        if (choice == PENALTY_SENDBUDDY && buddy == address(0)) {
            revert SmartAccount__InvalidPenaltyConfig();
        }
        if (choice == PENALTY_DELAYEDPAYMENT && delayDuration == 0) {
            revert SmartAccount__InvalidPenaltyConfig();
        }
        if (rewardAmount == 0) {
            revert SmartAccount__RewardCannotBeZero();
        }
        (uint256 taskId, bool valid) =
            taskManager.createTask(description, rewardAmount, deadlineInSeconds, choice, delayDuration, buddy);
        if (!valid) {
            revert SmartAccount__TaskCreationFailed();
        }

        s_totalCommittedReward += rewardAmount;
        emit TaskCreated(taskId, description, rewardAmount);
    }

    function completeTask(uint256 taskId) external onlyOwner taskManagerLinked nonReentrant {
        TaskManager.Task memory task = taskManager.getTask(taskId);
        if (task.status == TaskManager.TaskStatus.COMPLETED) {
            revert SmartAccount__TaskAlreadyCompleted();
        }
        taskManager.completeTask(taskId);

        if (task.rewardAmount > 0) {
            s_totalCommittedReward -= task.rewardAmount;
            (bool success,) = payable(msg.sender).call{value: task.rewardAmount}("");
            if (!success) {
                revert SmartAccount__TaskRewardPaymentFailed();
            }
        }

        emit TaskCompleted(taskId);
    }

    function cancelTask(uint256 taskId) external onlyOwner taskManagerLinked {
        TaskManager.Task memory task = taskManager.getTask(taskId);
        if (task.status == TaskManager.TaskStatus.CANCELED) {
            revert SmartAccount__TaskAlreadyCanceled();
        }
        taskManager.cancelTask(taskId);
        s_totalCommittedReward -= task.rewardAmount;
        emit TaskCanceled(taskId);
    }

    function getTask(uint256 taskId) external view taskManagerLinked returns (TaskManager.Task memory) {
        return taskManager.getTask(taskId);
    }

    function getTotalTasks() external view taskManagerLinked returns (uint256) {
        return taskManager.getTotalTasks();
    }

    function getAllTasks() external view taskManagerLinked returns (TaskManager.Task[] memory) {
        return taskManager.getAllTasks();
    }

    /*//////////////////////////////////////////////////////////////
                         PENALTY MECHANISMS
    //////////////////////////////////////////////////////////////*/

    function expiredTaskCallback(uint256 taskId) external nonReentrant {
        if (msg.sender != address(taskManager)) {
            revert SmartAccount__OnlyTaskManagerCanCall();
        }

        TaskManager.Task memory task = taskManager.getTask(taskId);

        if (task.status != TaskManager.TaskStatus.EXPIRED) {
            revert SmartAccount__TaskNotExpired();
        }

        if (task.choice == PENALTY_DELAYEDPAYMENT) {
            emit DurationPenaltyApplied(taskId, task.deadline + task.delayDuration);
        } else if (task.choice == PENALTY_SENDBUDDY) {
            if (task.buddy == address(0)) {
                revert SmartAccount__PickAPenalty();
            }

            s_totalCommittedReward -= task.rewardAmount;
            (bool success,) = payable(task.buddy).call{value: task.rewardAmount}("");
            if (!success) {
                revert SmartAccount__TaskRewardPaymentFailed();
            }
            emit PenaltyFundsReleasedToBuddy(taskId, task.rewardAmount, task.buddy);
        } else {
            revert SmartAccount__InvalidPenaltyChoice();
        }

        emit TaskExpired(taskId);
    }

    function expireTask(uint256 taskId) external onlyOwner taskManagerLinked {
        taskManager.expireTask(taskId);
        emit TaskExpired(taskId);
    }

    function releaseDelayedPayment(uint256 taskId) external onlyOwner taskManagerLinked nonReentrant {
        TaskManager.Task memory task = taskManager.getTask(taskId);
        if (task.choice != PENALTY_DELAYEDPAYMENT) {
            revert SmartAccount__PenaltyTypeMismatch();
        }
        if (task.status != TaskManager.TaskStatus.EXPIRED) {
            revert SmartAccount__TaskNotExpired();
        }
        if (block.timestamp <= task.deadline + task.delayDuration) {
            revert SmartAccount__PenaltyDurationNotElapsed();
        }
        uint256 releaseTime = task.deadline + task.delayDuration;
        if (block.timestamp < releaseTime) {
            revert SmartAccount__PenaltyDurationNotElapsed();
        }

        if (s_totalCommittedReward < task.rewardAmount) {
            revert SmartAccount__InsufficientCommittedReward();
        }
        if (task.delayedRewardReleased) {
            revert SmartAccount__PaymentAlreadyReleased();
        }
        taskManager.releaseDelayedPayment(taskId);
        s_totalCommittedReward -= task.rewardAmount;
        (bool success,) = payable(s_owner).call{value: task.rewardAmount}("");
        if (!success) {
            revert SmartAccount__TaskRewardPaymentFailed();
        }

        emit DelayedPaymentReleased(taskId, task.rewardAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/
    fallback() external payable {}
}
