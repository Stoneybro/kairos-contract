// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISmartAccount} from "./interface/ISmartAccount.sol";
import {ITaskManager} from "./interface/ITaskManager.sol";

/**
 * @title TaskManager
 * @notice Manages tasks for SmartAccount clones.
 * @author Livingstone Z.
 * @dev
 * - Uses a min-heap keyed by deadline for scheduling expirations (global).
 * - Maintains per-account arrays of taskIds by status for efficient pagination.
 * - Ensures tasks are removed from pending structures on any status transition.
 * - Safe ordering: internal state updated before any external callback to accounts.
 *
 * Notes:
 * - getTasksByStatus is paginated and cheap. getAllTasks is intentionally omitted.
 * - Heap index and status-index mappings store index+1 to allow 0 meaning 'not present'.
 */
contract TaskManager is ITaskManager, AutomationCompatibleInterface, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    // Tasks storage: account => taskId => Task
    mapping(address => mapping(uint256 => Task)) private s_tasks;

    // Per-account task counter (next id)
    mapping(address => uint256) private s_taskCounters;

    // Per-account lists by status: account => status(uint8) => array of taskIds
    mapping(address => mapping(uint8 => uint256[])) private s_tasksByStatus;

    // Index mapping for tasks in the per-status arrays: account => taskId => index+1 (0 means absent)
    mapping(address => mapping(uint256 => uint256)) private s_taskIndexInStatus;

    // Global min-heap of pending tasks (by deadline)
    struct HeapItem {
        address account;
        uint256 taskId;
        uint256 deadline;
    }

    HeapItem[] private s_heap;

    // Heap index mapping: key => index+1 (0 means absent)
    mapping(bytes32 => uint256) private s_heapIndex;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TaskCreated(address indexed account, uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(address indexed account, uint256 indexed taskId);
    event TaskCanceled(address indexed account, uint256 indexed taskId);
    event TaskExpired(address indexed account, uint256 indexed taskId);
    event TaskExpiredCallFailure(address indexed account, uint256 indexed taskId);
    event TaskDelayedPaymentReleased(address indexed account, uint256 indexed taskId, uint256 indexed rewardAmount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TaskManager__TaskDoesntExist();
    error TaskManager__EmptyDescription();
    error TaskManager__RewardAmountMustBeGreaterThanZero();
    error TaskManager__InvalidPenaltyConfig();
    error TaskManager__TaskAlreadyCompleted();
    error TaskManager__TaskHasBeenCanceled();
    error TaskManager__TaskHasExpired();
    error TaskManager__TaskNotYetExpired();
    error TaskManager__InvalidChoice();
    error TaskManager__AlreadyReleased();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {}

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS / KEYS
    //////////////////////////////////////////////////////////////*/

    function _heapKey(address account, uint256 taskId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, taskId));
    }

    modifier taskExist(address account, uint256 taskId) {
        if (taskId >= s_taskCounters[account]) {
            revert TaskManager__TaskDoesntExist();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              HEAP OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function _heapPush(HeapItem memory item) internal {
        s_heap.push(item);
        uint256 idx = s_heap.length - 1;
        s_heapIndex[_heapKey(item.account, item.taskId)] = idx + 1; // store index+1
        _siftUp(idx);
    }

    function _heapRoot() internal view returns (HeapItem memory) {
        require(s_heap.length > 0, "Heap empty");
        return s_heap[0];
    }

    function _heapRemove(address account, uint256 taskId) internal {
        if (s_heap.length == 0) return;
        bytes32 key = _heapKey(account, taskId);
        uint256 idxPlusOne = s_heapIndex[key];
        if (idxPlusOne == 0) return; // not in heap
        uint256 idx = idxPlusOne - 1;
        uint256 last = s_heap.length - 1;

        if (idx != last) {
            // move last to idx
            _heapSwap(idx, last);
        }

        // pop last
        HeapItem memory removed = s_heap[s_heap.length - 1];
        s_heap.pop();
        delete s_heapIndex[_heapKey(removed.account, removed.taskId)];

        if (idx < s_heap.length) {
            // restore heap property at idx
            _siftDown(idx);
            _siftUp(idx);
        }
    }

    function _heapPopRoot() internal returns (HeapItem memory root) {
        require(s_heap.length > 0, "Heap empty");
        root = s_heap[0];
        _heapRemove(root.account, root.taskId);
    }

    function _heapSwap(uint256 i, uint256 j) internal {
        HeapItem memory a = s_heap[i];
        HeapItem memory b = s_heap[j];
        s_heap[i] = b;
        s_heap[j] = a;
        s_heapIndex[_heapKey(a.account, a.taskId)] = j + 1;
        s_heapIndex[_heapKey(b.account, b.taskId)] = i + 1;
    }

    function _siftUp(uint256 idx) internal {
        while (idx > 0) {
            uint256 parent = (idx - 1) >> 1;
            if (s_heap[parent].deadline <= s_heap[idx].deadline) break;
            _heapSwap(parent, idx);
            idx = parent;
        }
    }

    function _siftDown(uint256 idx) internal {
        uint256 len = s_heap.length;
        while (true) {
            uint256 left = (idx << 1) + 1;
            uint256 right = left + 1;
            uint256 smallest = idx;

            if (left < len && s_heap[left].deadline < s_heap[smallest].deadline) smallest = left;
            if (right < len && s_heap[right].deadline < s_heap[smallest].deadline) smallest = right;

            if (smallest == idx) break;
            _heapSwap(idx, smallest);
            idx = smallest;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         STATUS-INDEXED HELPERS
    //////////////////////////////////////////////////////////////*/

    // Note: we store indexes as index+1. 0 means not present.
    function _pushTaskToStatus(address account, uint8 status, uint256 taskId) internal {
        uint256[] storage arr = s_tasksByStatus[account][status];
        arr.push(taskId);
        s_taskIndexInStatus[account][taskId] = arr.length; // store index+1
    }

    function _removeTaskFromStatus(address account, uint8 status, uint256 taskId) internal {
        uint256 idxPlusOne = s_taskIndexInStatus[account][taskId];
        if (idxPlusOne == 0) return; // not present
        uint256 idx = idxPlusOne - 1;
        uint256[] storage arr = s_tasksByStatus[account][status];
        uint256 last = arr.length - 1;

        if (idx != last) {
            uint256 movedTaskId = arr[last];
            arr[idx] = movedTaskId;
            s_taskIndexInStatus[account][movedTaskId] = idx + 1;
        }

        arr.pop();
        delete s_taskIndexInStatus[account][taskId];
    }

    function _moveTaskStatus(address account, uint8 oldStatus, uint8 newStatus, uint256 taskId) internal {
        if (oldStatus == newStatus) return;
        _removeTaskFromStatus(account, oldStatus, taskId);
        _pushTaskToStatus(account, newStatus, taskId);
    }

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a task for the caller account.
     * @dev Adds to heap and per-status array. Emits TaskCreated.
     */
    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external override nonReentrant returns (uint256) {
        address account = msg.sender;

        if (bytes(description).length == 0) revert TaskManager__EmptyDescription();
        if (rewardAmount == 0) revert TaskManager__RewardAmountMustBeGreaterThanZero();
        if (choice == 2 && buddy == address(0)) revert TaskManager__InvalidPenaltyConfig();
        if (choice == 1 && delayDuration == 0) revert TaskManager__InvalidPenaltyConfig();
        if (choice > 2 || choice == 0) revert TaskManager__InvalidChoice();

        uint256 deadline = block.timestamp + deadlineInSeconds;
        uint256 newTaskId = s_taskCounters[account];

        // Store task
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
            delayedRewardReleased: false,
            verificationMethod:VerificationMethod(verificationMethod)
        });

        // Add to pending status array
        _pushTaskToStatus(account, uint8(TaskStatus.PENDING), newTaskId);

        // Push to heap for scheduling
        _heapPush(HeapItem({account: account, taskId: newTaskId, deadline: deadline}));

        emit TaskCreated(account, newTaskId, description, rewardAmount);

        // increment counter
        unchecked {
            s_taskCounters[account] = newTaskId + 1;
        }

        return newTaskId;
    }

    /**
     * @notice Complete a task. Callable by the account that owns the task.
     */
    function completeTask(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status == TaskStatus.COMPLETED) revert TaskManager__TaskAlreadyCompleted();
        if (task.status != TaskStatus.PENDING) revert TaskManager__TaskHasBeenCanceled();

        // update status, arrays and heap
        task.status = TaskStatus.COMPLETED;
        _moveTaskStatus(account, uint8(TaskStatus.PENDING), uint8(TaskStatus.COMPLETED), taskId);
        _heapRemove(account, taskId);

        emit TaskCompleted(account, taskId);
    }

    /**
     * @notice Cancel a pending task. Callable by the account that owns the task.
     */
    function cancelTask(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status == TaskStatus.CANCELED) revert TaskManager__TaskHasBeenCanceled();
        if (task.status != TaskStatus.PENDING) revert TaskManager__TaskAlreadyCompleted();

        task.status = TaskStatus.CANCELED;
        _moveTaskStatus(account, uint8(TaskStatus.PENDING), uint8(TaskStatus.CANCELED), taskId);
        _heapRemove(account, taskId);

        emit TaskCanceled(account, taskId);
    }

    /**
     * @notice Perform upkeep to expire tasks.
     * @dev Removes expired tasks from heap and status arrays first, then calls account callback.
     */
    function checkUpkeep(bytes calldata) external override view returns (bool upkeepNeeded, bytes memory performData) {
        if (s_heap.length == 0) return (false, "");
        HeapItem memory root = s_heap[0];
        upkeepNeeded = (block.timestamp > root.deadline && root.deadline != 0);
        performData = abi.encode(root.account, root.taskId);
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        (address account, uint256 taskId) = abi.decode(performData, (address, uint256));

        // Validate heap root matches request and is expired
        if (s_heap.length == 0) return;
        HeapItem memory root = s_heap[0];
        if (root.account != account || root.taskId != taskId) return;

        Task storage task = s_tasks[account][taskId];
        if (!(block.timestamp > task.deadline && task.status == TaskStatus.PENDING)) return;

        // Transition first: mark expired, update status arrays and remove from heap
        task.status = TaskStatus.EXPIRED;
        _moveTaskStatus(account, uint8(TaskStatus.PENDING), uint8(TaskStatus.EXPIRED), taskId);
        _heapRemove(account, taskId);

        // After internal state is safe, call external account callback
        emit TaskExpired(account, taskId);

        try ISmartAccount(account).expiredTaskCallback(taskId) {
            // success
        } catch {
            emit TaskExpiredCallFailure(account, taskId);
        }
    }

    /**
     * @notice Release delayed payment after expiration delay. Callable by account.
     */
    function releaseDelayedPayment(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status != TaskStatus.EXPIRED) revert TaskManager__TaskNotYetExpired();
        if (task.choice != 1) revert TaskManager__InvalidPenaltyConfig(); // PENALTY_DELAYEDPAYMENT
        if (task.delayedRewardReleased) revert TaskManager__AlreadyReleased();

        task.delayedRewardReleased = true;
        emit TaskDelayedPaymentReleased(account, taskId, task.rewardAmount);
    }

    /*//////////////////////////////////////////////////////////////
                               PAGINATED GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fetch tasks for an account by status with pagination.
     * @param account Account whose tasks to query.
     * @param status TaskStatus enum value.
     * @param start Start index (0-based) in the status array.
     * @param limit Max number of tasks to return.
     */
    function getTasksByStatus(address account, TaskStatus status, uint256 start, uint256 limit)
        external
        view
        returns (Task[] memory out)
    {
        uint8 s = uint8(status);
        uint256[] storage ids = s_tasksByStatus[account][s];
        uint256 total = ids.length;

        if (start >= total || limit == 0) return new Task[](0);

        uint256 end = start + limit;
        if (end > total) end = total;
        uint256 n = end - start;

        out = new Task[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = s_tasks[account][ids[start + i]];
        }
    }

    /**
     * @notice Get the number of tasks for an account, grouped by status
     * @param account The account whose task counts are requested
     * @return counts An array where counts[i] = number of tasks with TaskStatus(i)
     */
    function getTaskCountsByStatus(address account) 
        external 
        view 
        returns (uint256[] memory counts) 
    {
        uint8 numStatuses = uint8(type(TaskStatus).max) + 1;
        counts = new uint256[](numStatuses);

        for (uint8 i = 0; i < numStatuses; i++) {
            counts[i] = s_tasksByStatus[account][i].length;
        }
    }

    /**
     * @notice Returns a single Task.
     */
    function getTask(address account, uint256 taskId)
        external
        view
        override
        taskExist(account, taskId)
        returns (Task memory)
    {
        return s_tasks[account][taskId];
    }

    /**
     * @notice Returns total tasks created for an account (counter).
     */
    function getTotalTasks(address account) external view override returns (uint256) {
        return s_taskCounters[account];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERFACE SUPPORT
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITaskManager).interfaceId
            || interfaceId == type(AutomationCompatibleInterface).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
