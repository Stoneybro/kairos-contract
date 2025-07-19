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
contract SimpleAccount is Initializable, IAccount, ReentrancyGuard {
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

    event TaskManagerLinked(address indexed taskManager);
    event TaskManagerUnlinked();
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

    error SimpleAccount__OnlyOwnerCanCall();
    error SimpleAccount__NotFromEntryPoint();
    error SimpleAccount__ExecutionFailed(bytes result);
    error SimpleAccount__TaskManagerAlreadyDeployed();
    error SimpleAccount__AddMoreFunds();
    error SimpleAccount__TaskCreationFailed();
    error SimpleAccount__TaskRewardPaymentFailed();
    error SimpleAccount__OnlyTaskManagerCanCall();
    error SimpleAccount__PenaltyDurationNotElapsed();
    error SimpleAccount__PenaltyTypeMismatch();
    error SimpleAccount__PayPrefundFailed();
    error SimpleAccount__UnlinkCurrentTaskManager();
    error SimpleAccount__PickAPenalty();
    error SimpleAccount__InvalidPenaltyChoice();
    error SimpleAccount__TaskManagerNotLinked();
    error SimpleAccount__NoTaskManagerLinked();
    error SimpleAccount__CannotWithdrawCommittedRewards();
    error SimpleAccount__TransferFailed();
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
            revert SimpleAccount__NotFromEntryPoint();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != s_owner) {
            revert SimpleAccount__OnlyOwnerCanCall();
        }
        _;
    }

    modifier contractFundedForTasks(uint256 rewardAmount) {
        if (address(this).balance < s_totalCommittedReward + rewardAmount) {
            revert SimpleAccount__AddMoreFunds();
        }
        _;
    }

    modifier taskManagerLinked() {
        if (address(taskManager) == address(0)) {
            revert SimpleAccount__NoTaskManagerLinked();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           ACCOUNT FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {}

    function execute(address dest, uint256 value, bytes calldata functionData) external nonReentrant {
        (bool success, bytes memory result) = dest.call{value: value}(functionData);
        if (!success) {
            revert SimpleAccount__ExecutionFailed(result);
        }
    }

    function transfer(address destination, uint256 value) external nonReentrant onlyOwner {
        if (value == 0) return;
        if (value > (address(this).balance - s_totalCommittedReward)) {
            revert SimpleAccount__CannotWithdrawCommittedRewards();
        }
        (bool success,) = destination.call{value: value}("");
        if (!success) {
            revert SimpleAccount__TransferFailed();
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

    function _payPrefund(uint256 missingAccountFunds) internal nonReentrant {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(address(i_entryPoint)).call{value: missingAccountFunds}("");
            if (!success) {
                revert SimpleAccount__PayPrefundFailed();
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
        uint256 durationInSeconds,
        uint8 choice,
        address buddy,
        uint256 delayDuration
    ) external onlyOwner taskManagerLinked contractFundedForTasks(rewardAmount) {
        if (choice == 0) {
            revert SimpleAccount__PickAPenalty();
        }
        if (choice > 2) {
            revert SimpleAccount__InvalidPenaltyChoice();
        }

        (uint256 taskId, bool valid) =
            taskManager.createTask(description, rewardAmount, durationInSeconds, choice, delayDuration, buddy);
        if (!valid) {
            revert SimpleAccount__TaskCreationFailed();
        }

        s_totalCommittedReward += rewardAmount;
        emit TaskCreated(taskId, description, rewardAmount);
    }

    function completeTask(uint256 taskId) external onlyOwner taskManagerLinked nonReentrant {
        TaskManager.Task memory task = taskManager.getTask(taskId);
        taskManager.completeTask(taskId);

        if (task.rewardAmount > 0) {
            s_totalCommittedReward -= task.rewardAmount;
            (bool success,) = payable(address(this)).call{value: task.rewardAmount}("");
            if (!success) {
                revert SimpleAccount__TaskRewardPaymentFailed();
            }
        }

        emit TaskCompleted(taskId);
    }

    function cancelTask(uint256 taskId) external onlyOwner taskManagerLinked {
        TaskManager.Task memory task = taskManager.getTask(taskId);
        taskManager.cancelTask(taskId);
        s_totalCommittedReward -= task.rewardAmount;
        emit TaskCanceled(taskId);
    }

    function getSumOfActiveTasksRewards() external view taskManagerLinked returns (uint256 totalTaskRewards) {
        uint256 taskNo = taskManager.getTotalTasks();

        for (uint256 i = 0; i < taskNo; i++) {
            // Check if task exists before getting it
            if (taskManager.isValidTask(i)) {
                TaskManager.Task memory task = taskManager.getTask(i);
                if (task.status == TaskManager.TaskStatus.PENDING) {
                    totalTaskRewards += task.rewardAmount;
                }
            }
        }
    }

    function getTask(uint256 taskId) external view returns (TaskManager.Task memory) {
        if (address(taskManager) == address(0)) {
            revert SimpleAccount__NoTaskManagerLinked();
        }
        return taskManager.getTask(taskId);
    }

    function getTotalTasks() external view returns (uint256) {
        if (address(taskManager) == address(0)) {
            revert SimpleAccount__NoTaskManagerLinked();
        }
        return taskManager.getTotalTasks();
    }

    function getAllTasks() external view returns (TaskManager.Task[] memory) {
        if (address(taskManager) == address(0)) {
            revert SimpleAccount__NoTaskManagerLinked();
        }
        return taskManager.getAllTasks();
    }

    /*//////////////////////////////////////////////////////////////
                         PENALTY MECHANISMS
    //////////////////////////////////////////////////////////////*/

    function expiredTaskCallback(uint256 taskId) external nonReentrant {
        if (msg.sender != address(taskManager)) {
            revert SimpleAccount__OnlyTaskManagerCanCall();
        }
        TaskManager taskMgr = TaskManager(msg.sender);
        TaskManager.Task memory task = taskMgr.getTask(taskId);

        if (task.choice == PENALTY_DELAYEDPAYMENT) {
            emit DurationPenaltyApplied(taskId, task.deadline + task.delayDuration);
        } else if (task.choice == PENALTY_SENDBUDDY) {
            if (task.buddy == address(0)) {
                revert SimpleAccount__PickAPenalty();
            }
            s_totalCommittedReward -= task.rewardAmount;
            (bool success,) = payable(task.buddy).call{value: task.rewardAmount}("");
            if (!success) {
                revert SimpleAccount__TaskRewardPaymentFailed();
            }
            emit PenaltyFundsReleasedToBuddy(taskId, task.rewardAmount, task.buddy);
        } else {
            revert SimpleAccount__InvalidPenaltyChoice();
        }

        emit TaskExpired(taskId);
    }

    function releaseDelayedPayment(uint256 taskId) external onlyOwner taskManagerLinked nonReentrant {
        TaskManager.Task memory task = taskManager.getTask(taskId);

        if (task.choice != PENALTY_DELAYEDPAYMENT) {
            revert SimpleAccount__PenaltyTypeMismatch();
        }
        if (block.timestamp < task.deadline + task.delayDuration) {
            revert SimpleAccount__PenaltyDurationNotElapsed();
        }

        s_totalCommittedReward -= task.rewardAmount;
        (bool success,) = payable(s_owner).call{value: task.rewardAmount}("");
        if (!success) {
            revert SimpleAccount__TaskRewardPaymentFailed();
        }

        emit DelayedPaymentReleased(taskId, task.rewardAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/
    fallback() external payable {}
}
