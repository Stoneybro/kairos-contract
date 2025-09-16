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
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/
    

    // Gas limit for buddy transfers to prevent griefing
    uint256 private constant BUDDY_TRANSFER_GAS_LIMIT = 50000;

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

    // Heap for ACTIVE tasks (by deadline)
    struct HeapItem {
        address account;
        uint256 taskId;
        uint256 deadline;
    }

    HeapItem[] private s_expirationHeap;
    mapping(bytes32 => uint256) private s_expirationHeapIndex;

    // Heap for delayed payment releases (by release timestamp)
    HeapItem[] private s_delayedPaymentHeap;
    mapping(bytes32 => uint256) private s_delayedPaymentHeapIndex;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TaskCreated(address indexed account, uint256 indexed taskId, string description, uint256 indexed rewardAmount);
    event TaskCompleted(address indexed account, uint256 indexed taskId);
    event TaskCanceled(address indexed account, uint256 indexed taskId);
    event TaskExpired(address indexed account, uint256 indexed taskId);
    event TaskExpiredCallFailure(address indexed account, uint256 indexed taskId, string reason);
    event TaskDelayedPaymentReleased(address indexed account, uint256 indexed taskId, uint256 indexed rewardAmount);
    event TaskBuddyPaymentSent(address indexed account, uint256 indexed taskId, uint256 indexed rewardAmount, address buddy);
    event TaskBuddyPaymentFailed(address indexed account, uint256 indexed taskId, address indexed buddy, string reason);
    event DelayedPaymentAutomationScheduled(address indexed account, uint256 indexed taskId, uint256 indexed releaseTimestamp);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TaskManager__TaskDoesntExist();
    error TaskManager__InvalidPenaltyConfig();
    error TaskManager__TaskAlreadyCompleted();
    error TaskManager__TaskHasBeenCanceled();
    error TaskManager__TaskHasExpired();
    error TaskManager__TaskNotYetExpired();
    error TaskManager__InvalidChoice();
    error TaskManager__AlreadyReleased();
    error TaskManager__TaskIsNotACTIVE();
    error TaskManager__BuddyPaymentAlreadySent();
    error TaskManager__TaskNotExpired();
    error TaskManager__InvalidPenaltyType();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {}

    /*//////////////////////////////////////////////////////////////
                               HEAP HELPERS
    //////////////////////////////////////////////////////////////*/

    function _heapKey(address account, uint256 taskId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, taskId));
    }

    // Generic heap operations that work with both heaps
    function _heapPush(HeapItem[] storage heap, mapping(bytes32 => uint256) storage heapIndex, HeapItem memory item) internal {
        heap.push(item);
        uint256 idx = heap.length - 1;
        heapIndex[_heapKey(item.account, item.taskId)] = idx + 1;
        _siftUp(heap, heapIndex, idx);
    }

    function _heapRemove(HeapItem[] storage heap, mapping(bytes32 => uint256) storage heapIndex, address account, uint256 taskId) internal {
        if (heap.length == 0) return;
        bytes32 key = _heapKey(account, taskId);
        uint256 idxPlusOne = heapIndex[key];
        if (idxPlusOne == 0) return;
        
        uint256 idx = idxPlusOne - 1;
        
        // FIXED: Validate the item matches before removing
        if (heap[idx].account != account || heap[idx].taskId != taskId) {
            return; // Item doesn't match, skip removal
        }
        
        uint256 last = heap.length - 1;

        if (idx != last) {
            _heapSwap(heap, heapIndex, idx, last);
        }

        HeapItem memory removed = heap[heap.length - 1];
        heap.pop();
        delete heapIndex[_heapKey(removed.account, removed.taskId)];

        if (idx < heap.length) {
            _siftDown(heap, heapIndex, idx);
            _siftUp(heap, heapIndex, idx);
        }
    }

    function _heapSwap(HeapItem[] storage heap, mapping(bytes32 => uint256) storage heapIndex, uint256 i, uint256 j) internal {
        HeapItem memory a = heap[i];
        HeapItem memory b = heap[j];
        heap[i] = b;
        heap[j] = a;
        heapIndex[_heapKey(a.account, a.taskId)] = j + 1;
        heapIndex[_heapKey(b.account, b.taskId)] = i + 1;
    }

    function _siftUp(HeapItem[] storage heap, mapping(bytes32 => uint256) storage heapIndex, uint256 idx) internal {
        while (idx > 0) {
            uint256 parent = (idx - 1) >> 1;
            if (heap[parent].deadline <= heap[idx].deadline) break;
            _heapSwap(heap, heapIndex, parent, idx);
            idx = parent;
        }
    }

    function _siftDown(HeapItem[] storage heap, mapping(bytes32 => uint256) storage heapIndex, uint256 idx) internal {
        uint256 len = heap.length;
        while (true) {
            uint256 left = (idx << 1) + 1;
            uint256 right = left + 1;
            uint256 smallest = idx;

            if (left < len && heap[left].deadline < heap[smallest].deadline) smallest = left;
            if (right < len && heap[right].deadline < heap[smallest].deadline) smallest = right;

            if (smallest == idx) break;
            _heapSwap(heap, heapIndex, idx, smallest);
            idx = smallest;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         STATUS-INDEXED HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pushTaskToStatus(address account, uint8 status, uint256 taskId) internal {
        uint256[] storage arr = s_tasksByStatus[account][status];
        arr.push(taskId);
        s_taskIndexInStatus[account][taskId] = arr.length;
    }

    function _removeTaskFromStatus(address account, uint8 status, uint256 taskId) internal {
        uint256 idxPlusOne = s_taskIndexInStatus[account][taskId];
        if (idxPlusOne == 0) return;
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

    function createTask(
        string calldata title,
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external override nonReentrant returns (uint256) {
        address account = msg.sender;
        
        uint256 deadline = block.timestamp + deadlineInSeconds;
        
        uint256 newTaskId = s_taskCounters[account];

        s_tasks[account][newTaskId] = Task({
            id: newTaskId,
            title: title,
            description: description,
            rewardAmount: rewardAmount,
            deadline: deadline,
            valid: true,
            status: TaskStatus.ACTIVE,
            choice: choice,
            delayDuration: delayDuration,
            buddy: buddy,
            delayedRewardReleased: false,
            buddyPaymentSent: false, // NEW: Initialize buddy payment flag
            verificationMethod: VerificationMethod(verificationMethod)
        });

        _pushTaskToStatus(account, uint8(TaskStatus.ACTIVE), newTaskId);
        
        // Add to expiration heap
        _heapPush(s_expirationHeap, s_expirationHeapIndex, 
                 HeapItem({account: account, taskId: newTaskId, deadline: deadline}));

        emit TaskCreated(account, newTaskId, description, rewardAmount);

        unchecked {
            s_taskCounters[account] = newTaskId + 1;
        }

        return newTaskId;
    }

    function completeTask(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status == TaskStatus.COMPLETED) revert TaskManager__TaskAlreadyCompleted();
        if (task.status != TaskStatus.ACTIVE) revert TaskManager__TaskIsNotACTIVE();

        task.status = TaskStatus.COMPLETED;
        _moveTaskStatus(account, uint8(TaskStatus.ACTIVE), uint8(TaskStatus.COMPLETED), taskId);
        _heapRemove(s_expirationHeap, s_expirationHeapIndex, account, taskId);

        emit TaskCompleted(account, taskId);
    }

    function cancelTask(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status == TaskStatus.CANCELED) revert TaskManager__TaskHasBeenCanceled();
        if (task.status != TaskStatus.ACTIVE) revert TaskManager__TaskIsNotACTIVE();

        task.status = TaskStatus.CANCELED;
        _moveTaskStatus(account, uint8(TaskStatus.ACTIVE), uint8(TaskStatus.CANCELED), taskId);
        _heapRemove(s_expirationHeap, s_expirationHeapIndex, account, taskId);

        emit TaskCanceled(account, taskId);
    }

    /*//////////////////////////////////////////////////////////////
                         ENHANCED AUTOMATION
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        // Check task expirations first (higher priority)
        if (s_expirationHeap.length > 0) {
            HeapItem memory expRoot = s_expirationHeap[0];
            if (block.timestamp > expRoot.deadline && expRoot.deadline != 0) {
                return (true, abi.encode(0, expRoot.account, expRoot.taskId)); // type 0 = expiration
            }
        }

        // Check delayed payment releases
        if (s_delayedPaymentHeap.length > 0) {
            HeapItem memory payRoot = s_delayedPaymentHeap[0];
            if (block.timestamp >= payRoot.deadline && payRoot.deadline != 0) {
                return (true, abi.encode(1, payRoot.account, payRoot.taskId)); // type 1 = delayed payment
            }
        }

        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        (uint8 upkeepType, address account, uint256 taskId) = abi.decode(performData, (uint8, address, uint256));

        if (upkeepType == 0) {
            _handleTaskExpiration(account, taskId);
        } else if (upkeepType == 1) {
            _handleDelayedPaymentRelease(account, taskId);
        }
    }

    function _handleTaskExpiration(address account, uint256 taskId) internal {
        if (s_expirationHeap.length == 0) return;
        HeapItem memory root = s_expirationHeap[0];
        if (root.account != account || root.taskId != taskId) return;

        Task storage task = s_tasks[account][taskId];
        if (!(block.timestamp > task.deadline && task.status == TaskStatus.ACTIVE)) return;

        // Update internal state first (CEI pattern)
        task.status = TaskStatus.EXPIRED;
        _moveTaskStatus(account, uint8(TaskStatus.ACTIVE), uint8(TaskStatus.EXPIRED), taskId);
        _heapRemove(s_expirationHeap, s_expirationHeapIndex, account, taskId);

        // For delayed payment penalties, schedule automated release
        if (task.choice == 1) { // PENALTY_DELAYEDPAYMENT
            uint256 releaseTimestamp = task.deadline + task.delayDuration;
            _heapPush(s_delayedPaymentHeap, s_delayedPaymentHeapIndex,
                     HeapItem({account: account, taskId: taskId, deadline: releaseTimestamp}));
            
            emit DelayedPaymentAutomationScheduled(account, taskId, releaseTimestamp);
        }

        emit TaskExpired(account, taskId);

        // FIXED: Better error handling for external calls
        try ISmartAccount(account).expiredTaskCallback(taskId) {
            // success
        } catch Error(string memory reason) {
            emit TaskExpiredCallFailure(account, taskId, reason);
        } catch (bytes memory) {
            emit TaskExpiredCallFailure(account, taskId, "Low-level call failed");
        }
    }

    function _handleDelayedPaymentRelease(address account, uint256 taskId) internal {
        if (s_delayedPaymentHeap.length == 0) return;
        HeapItem memory root = s_delayedPaymentHeap[0];
        if (root.account != account || root.taskId != taskId) return;

        Task storage task = s_tasks[account][taskId];
        if (task.status != TaskStatus.EXPIRED || task.choice != 1 || task.delayedRewardReleased) return;
        if (block.timestamp < task.deadline + task.delayDuration) return;

        // Update state first (CEI pattern)
        task.delayedRewardReleased = true;
        _heapRemove(s_delayedPaymentHeap, s_delayedPaymentHeapIndex, account, taskId);

        emit TaskDelayedPaymentReleased(account, taskId, task.rewardAmount);

        // Call account to release the funds
        try ISmartAccount(account).automatedDelayedPaymentRelease(taskId) {
            // success
        } catch Error(string memory reason) {
            emit TaskExpiredCallFailure(account, taskId, reason);
        } catch (bytes memory) {
            emit TaskExpiredCallFailure(account, taskId, "Delayed payment release failed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                         MANUAL RELEASE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // Keep manual delayed payment release as fallback
    function releaseDelayedPayment(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status != TaskStatus.EXPIRED) revert TaskManager__TaskNotYetExpired();
        if (task.choice != 1) revert TaskManager__InvalidPenaltyConfig();
        if (task.delayedRewardReleased) revert TaskManager__AlreadyReleased();
        if (block.timestamp < task.deadline + task.delayDuration) revert TaskManager__TaskNotYetExpired();

        task.delayedRewardReleased = true;
        
        // Remove from automation heap if present
        _heapRemove(s_delayedPaymentHeap, s_delayedPaymentHeapIndex, account, taskId);
        
        emit TaskDelayedPaymentReleased(account, taskId, task.rewardAmount);
    }

    // NEW: Manual buddy payment release
    function releaseBuddyPayment(uint256 taskId) external override nonReentrant taskExist(msg.sender, taskId) {
        address account = msg.sender;
        Task storage task = s_tasks[account][taskId];

        if (task.status != TaskStatus.EXPIRED) revert TaskManager__TaskNotExpired();
        if (task.choice != 2) revert TaskManager__InvalidPenaltyType();
        if (task.buddyPaymentSent) revert TaskManager__BuddyPaymentAlreadySent();
        if (task.buddy == address(0)) revert TaskManager__InvalidPenaltyConfig();

        // Update state first
        task.buddyPaymentSent = true;

        // Attempt to send payment to buddy via SmartAccount
        try ISmartAccount(account).automatedBuddyPaymentAttempt(taskId) returns (bool success) {
            if (success) {
                emit TaskBuddyPaymentSent(account, taskId, task.rewardAmount, task.buddy);
            } else {
                // Reset flag if payment failed
                task.buddyPaymentSent = false;
                emit TaskBuddyPaymentFailed(account, taskId, task.buddy, "Payment attempt failed");
            }
        } catch Error(string memory reason) {
            // Reset flag if call failed
            task.buddyPaymentSent = false;
            emit TaskBuddyPaymentFailed(account, taskId, task.buddy, reason);
        } catch (bytes memory) {
            // Reset flag if call failed
            task.buddyPaymentSent = false;
            emit TaskBuddyPaymentFailed(account, taskId, task.buddy, "Low-level call failed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EXISTING GETTERS
    //////////////////////////////////////////////////////////////*/

    modifier taskExist(address account, uint256 taskId) {
        if (taskId >= s_taskCounters[account]) {
            revert TaskManager__TaskDoesntExist();
        }
        _;
    }

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

    function getTaskCountsByStatus(address account) external view returns (uint256[] memory counts) {
        uint8 numStatuses = uint8(type(TaskStatus).max) + 1;
        counts = new uint256[](numStatuses);

        for (uint8 i = 0; i < numStatuses; i++) {
            counts[i] = s_tasksByStatus[account][i].length;
        }
    }

    function getTask(address account, uint256 taskId)
        external
        view
        override
        taskExist(account, taskId)
        returns (Task memory)
    {
        return s_tasks[account][taskId];
    }

    function getTotalTasks(address account) external view override returns (uint256) {
        return s_taskCounters[account];
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITaskManager).interfaceId
            || interfaceId == type(AutomationCompatibleInterface).interfaceId 
            || interfaceId == type(IERC165).interfaceId;
    }
}