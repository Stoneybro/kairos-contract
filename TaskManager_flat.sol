// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0 ^0.8.19 ^0.8.20;

// lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/AutomationBase.sol

contract AutomationBase {
  error OnlySimulatedBackend();

  /**
   * @notice method that allows it to be simulated via eth_call by checking that
   * the sender is the zero address.
   */
  function _preventExecution() internal view {
    // solhint-disable-next-line avoid-tx-origin
    if (tx.origin != address(0) && tx.origin != address(0x1111111111111111111111111111111111111111)) {
      revert OnlySimulatedBackend();
    }
  }

  /**
   * @notice modifier that allows it to be simulated via eth_call by checking
   * that the sender is the zero address.
   */
  modifier cannotExecute() {
    _preventExecution();
    _;
  }
}

// lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol

// solhint-disable-next-line interface-starts-with-i
interface AutomationCompatibleInterface {
  /**
   * @notice method that is simulated by the keepers to see if any work actually
   * needs to be performed. This method does does not actually need to be
   * executable, and since it is only ever simulated it can consume lots of gas.
   * @dev To ensure that it is never called, you may want to add the
   * cannotExecute modifier from KeeperBase to your implementation of this
   * method.
   * @param checkData specified in the upkeep registration so it is always the
   * same for a registered upkeep. This can easily be broken down into specific
   * arguments using `abi.decode`, so multiple upkeeps can be registered on the
   * same contract and easily differentiated by the contract.
   * @return upkeepNeeded boolean to indicate whether the keeper should call
   * performUpkeep or not.
   * @return performData bytes that the keeper should call performUpkeep with, if
   * upkeep is needed. If you would like to encode data to decode later, try
   * `abi.encode`.
   */
  function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);

  /**
   * @notice method that is actually executed by the keepers, via the registry.
   * The data returned by the checkUpkeep simulation will be passed into
   * this method to actually be executed.
   * @dev The input to this method should not be trusted, and the caller of the
   * method should not even be restricted to any single registry. Anyone should
   * be able call it, and the input should be validated, there is no guarantee
   * that the data passed in is the performData returned from checkUpkeep. This
   * could happen due to malicious keepers, racing keepers, or simply a state
   * change while the performUpkeep transaction is waiting for confirmation.
   * Always validate the data passed in.
   * @param performData is the data which was passed back from the checkData
   * simulation. If it is encoded, it can easily be decoded into other types by
   * calling `abi.decode`. This data should not be trusted, and should be
   * validated against the contract's current state.
   */
  function performUpkeep(bytes calldata performData) external;
}

// lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// src/interface/ISmartAccount.sol

interface ISmartAccount is IERC165 {
    function expiredTaskCallback(uint256 taskId) external;
}

// src/interface/ITaskManager.sol

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

// lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/AutomationCompatible.sol

abstract contract AutomationCompatible is AutomationBase, AutomationCompatibleInterface {}

// src/TaskManager.sol

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
    
    function getAllTasks(address account) external view override returns (Task[] memory tasks) {
        uint256 taskCount = s_taskCounters[account];

        tasks = new Task[](taskCount);
        for (uint256 i = 0; i < taskCount; i++) {
            tasks[i] = s_tasks[account][ i];
        }
        return (tasks);
    }

    function getTotalTasks(address account) external view override returns (uint256) {
        return s_taskCounters[account];
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(ITaskManager).interfaceId ||
            interfaceId == type(AutomationCompatibleInterface).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}

