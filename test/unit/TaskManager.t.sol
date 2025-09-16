// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {TaskManager} from "src/TaskManager.sol";
import {ITaskManager} from "src/interface/ITaskManager.sol";
import {ISmartAccount} from "src/interface/ISmartAccount.sol";
import {UserOperation} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MockAccountSuccess is ISmartAccount {
    TaskManager public tm;
    bool public callbackCalled;
    uint256 public lastExpiredTaskId;
    address public lastCaller;

    constructor(TaskManager _tm) {
        tm = _tm;
    }

    // helper to create tasks through this contract (so msg.sender inside TaskManager is this contract)
    function createTaskOnManager(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external returns (uint256) {
        return tm.createTask(
            description, rewardAmount, deadlineInSeconds, choice, delayDuration, buddy, verificationMethod
        );
    }

    function completeTaskOnManager(uint256 taskId) external {
        tm.completeTask(taskId);
    }

    function cancelTaskOnManager(uint256 taskId) external {
        tm.cancelTask(taskId);
    }

    function releaseDelayedPaymentOnManager(uint256 taskId) external {
        tm.releaseDelayedPayment(taskId);
    }

    // Called by TaskManager when a task expires.
    function expiredTaskCallback(uint256 taskId) external override {
        callbackCalled = true;
        lastExpiredTaskId = taskId;
        lastCaller = msg.sender;
    }

    // stub for IAccount - not used in tests
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
    pure
        external
        returns (uint256 validationData)
    {
        userOpHash;
        userOp;
        missingAccountFunds;
        return 0;
    }

    function execute(address, uint256, bytes calldata) external {}

    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {}
}

contract MockAccountRevert is ISmartAccount {
    TaskManager public tm;

    constructor(TaskManager _tm) {
        tm = _tm;
    }

    // helpers
    function createTaskOnManager(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external returns (uint256) {
        return tm.createTask(
            description, rewardAmount, deadlineInSeconds, choice, delayDuration, buddy, verificationMethod
        );
    }

    // expired callback that reverts
    function expiredTaskCallback(uint256) external pure override {
        revert("callback revert");
    }

    // stubs for IAccount
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        pure
        returns (uint256 validationData)
    {
        userOp;
        userOpHash;
        missingAccountFunds;
        return 0;
    }

    function execute(address, uint256, bytes calldata) external {}

    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {}
}

contract TaskManagerTest is Test {
    TaskManager tm;
    MockAccountSuccess acc;
    MockAccountRevert accRevert;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        tm = new TaskManager();
        acc = new MockAccountSuccess(tm);
        accRevert = new MockAccountRevert(tm);
    }

    /*///////////////////////////////////////////////////////////////
                            CREATE TASK - NEGATIVES
    ///////////////////////////////////////////////////////////////*/

    function testCreateTask_emptyDescription_reverts() public {
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__EmptyDescription.selector);
        tm.createTask("", 1 ether, 1 days, 1, 1 days, address(0x1), 0);
    }

    function testCreateTask_zeroReward_reverts() public {
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__RewardAmountMustBeGreaterThanZero.selector);
        tm.createTask("t", 0, 1 days, 1, 1 days, address(0x1), 0);
    }

    function testCreateTask_invalidChoice_reverts() public {
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__InvalidChoice.selector);
        tm.createTask("t", 1, 1 days, 0, 1 days, address(0x1), 0);
    }

    function testCreateTask_invalidPenaltyConfig_buddyZero_reverts() public {
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        // choice == 2 requires buddy non-zero
        tm.createTask("t", 1, 1 days, 2, 1 days, address(0), 0);
    }

    function testCreateTask_invalidPenaltyConfig_delayZero_reverts() public {
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        // choice == 1 requires delayDuration non-zero
        tm.createTask("t", 1, 1 days, 1, 0, address(0x1), 0);
    }

    /*///////////////////////////////////////////////////////////////
                            CREATE TASK - POSITIVES
    ///////////////////////////////////////////////////////////////*/

    function testCreateTask_success_and_getters() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("do thing", 1 ether, 1 days, 1, 1 hours, address(0xBEEF), 0);
        assertEq(id, 0);

        // counters & task
        uint256 total = tm.getTotalTasks(address(acc));
        assertEq(total, 1);

        ITaskManager.Task memory t = tm.getTask(address(acc), id);
        assertEq(t.id, id);
        assertEq(t.rewardAmount, 1 ether);
        assertEq(uint8(t.status), uint8(ITaskManager.TaskStatus.PENDING));
    }

    /*///////////////////////////////////////////////////////////////
                         COMPLETE / CANCEL / STATUS FLOW
    ///////////////////////////////////////////////////////////////*/

    function testCompleteTask_success() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("c", 1, 1 days, 1, 1 hours, address(0x1), 0);

        vm.prank(address(acc));
        tm.completeTask(id);

        ITaskManager.Task memory t = tm.getTask(address(acc), id);
        assertEq(uint8(t.status), uint8(ITaskManager.TaskStatus.COMPLETED));

        // completing again reverts with already completed
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskAlreadyCompleted.selector);
        tm.completeTask(id);
    }

    function testCancelTask_success() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("x", 1, 1 days, 1, 1 hours, address(0x1), 0);

        vm.prank(address(acc));
        tm.cancelTask(id);

        ITaskManager.Task memory t = tm.getTask(address(acc), id);
        assertEq(uint8(t.status), uint8(ITaskManager.TaskStatus.CANCELED));

        // cancel again reverts
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
        tm.cancelTask(id);
    }

    function testCompleteTask_wrongStatus_reverts() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("x", 1, 1 days, 1, 1 hours, address(0x1), 0);

        // cancel it first
        vm.prank(address(acc));
        tm.cancelTask(id);

        // try to complete canceled -> should revert with has been canceled
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskIsNotPending.selector);
        tm.completeTask(id);
    }

    /*///////////////////////////////////////////////////////////////
                                HEAP / UPKEEP
    ///////////////////////////////////////////////////////////////*/

    function testHeapRoot_and_performUpkeep_success_callback() public {
        // create two tasks, deadlines: now+1 and now+2
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("t1", 1, 1, 1, 1, address(0x1), 0); // earliest
        vm.prank(address(acc));
        uint256 id2 = tm.createTask("t2", 1, 2, 1, 1, address(0x1), 0);

        // advance time past first deadline
        vm.warp(block.timestamp + 10);

        // checkUpkeep should be true and performData should point to root
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        (address a, uint256 tid) = abi.decode(data, (address, uint256));
        assertEq(a, address(acc));
        assertEq(tid, id1);

        // Perform upkeep: TaskManager will call expiredTaskCallback on acc
        // acc is MockAccountSuccess, so callback will set flag
        vm.prank(address(this));
        tm.performUpkeep(data);

        assertTrue(acc.callbackCalled());
        assertEq(acc.lastExpiredTaskId(), id1);

        // The expired task status should be EXPIRED
        ITaskManager.Task memory t = tm.getTask(address(acc), id1);
        assertEq(uint8(t.status), uint8(ITaskManager.TaskStatus.EXPIRED));
    }

    function testPerformUpkeep_callbackReverts_emitsFailure() public {
        // use mock account that reverts on callback
        vm.prank(address(accRevert));
        uint256 id = tm.createTask("r", 1, 1, 1, 1, address(0x1), 0);

        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);

        // call performUpkeep (this will catch the revert and emit TaskExpiredCallFailure)
        vm.prank(address(this));
        tm.performUpkeep(data);

        // status should be EXPIRED even after failed callback
        ITaskManager.Task memory t = tm.getTask(address(accRevert), id);
        assertEq(uint8(t.status), uint8(ITaskManager.TaskStatus.EXPIRED));
    }

    /*///////////////////////////////////////////////////////////////
                        RELEASE DELAYED PAYMENT
    ///////////////////////////////////////////////////////////////*/

    function testReleaseDelayedPayment_flow() public {
        // create delayed payment task (choice = 1)
        vm.prank(address(acc));
        uint256 id = tm.createTask("d", 1, 1, 1, 1, address(0x1), 0);

        // expire it
        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        vm.prank(address(this));
        tm.performUpkeep(data);

        // release delayed payment by account
        vm.prank(address(acc));
        tm.releaseDelayedPayment(id);

        ITaskManager.Task memory t = tm.getTask(address(acc), id);
        assertTrue(t.delayedRewardReleased);
    }

    function testReleaseDelayedPayment_wrongStatus_reverts() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("d", 1, 100 days, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskNotYetExpired.selector);
        tm.releaseDelayedPayment(id);
    }

    function testReleaseDelayedPayment_alreadyReleased_reverts() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("d", 1, 1, 1, 1, address(0x1), 0);

        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        vm.prank(address(this));
        tm.performUpkeep(data);

        vm.prank(address(acc));
        tm.releaseDelayedPayment(id);

        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__AlreadyReleased.selector);
        tm.releaseDelayedPayment(id);
    }
    // Additional test functions to add to TaskManagerTest contract

    /*///////////////////////////////////////////////////////////////
                    HEAP IMPLEMENTATION STRESS TESTS
    ///////////////////////////////////////////////////////////////*/

    function testHeap_multiple_accounts_ordering() public {
        MockAccountSuccess acc2 = new MockAccountSuccess(tm);

        // Create tasks with different deadlines across accounts
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("late", 1, 100, 1, 1, address(0x1), 0); // deadline: now + 100

        vm.prank(address(acc2));
        uint256 id2 = tm.createTask("early", 1, 50, 1, 1, address(0x1), 0); // deadline: now + 50

        vm.prank(address(acc));
        uint256 id3 = tm.createTask("earliest", 1, 10, 1, 1, address(0x1), 0); // deadline: now + 10

        // Advance past earliest deadline
        vm.warp(block.timestamp + 15);

        // First upkeep should process id3 (earliest deadline)
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        (address rootAccount, uint256 rootId) = abi.decode(data, (address, uint256));
        assertEq(rootAccount, address(acc));
        assertEq(rootId, id3);

        vm.prank(address(this));
        tm.performUpkeep(data);

        // Advance past second deadline
        vm.warp(block.timestamp + 45); // now at original + 60

        // Next upkeep should process id2
        (bool needed2, bytes memory data2) = tm.checkUpkeep("");
        assertTrue(needed2);
        (address rootAccount2, uint256 rootId2) = abi.decode(data2, (address, uint256));
        assertEq(rootAccount2, address(acc2));
        assertEq(rootId2, id2);
    }

    function testHeap_remove_from_middle() public {
        // Create 3 tasks with deadlines: 10, 20, 30
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("early", 1, 10, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        uint256 id2 = tm.createTask("middle", 1, 20, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        uint256 id3 = tm.createTask("late", 1, 30, 1, 1, address(0x1), 0);

        // Cancel the middle one (should remove from heap)
        vm.prank(address(acc));
        tm.cancelTask(id2);

        // Advance past first deadline
        vm.warp(block.timestamp + 15);

        // Should still process id1 correctly
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        (address rootAccount, uint256 rootId) = abi.decode(data, (address, uint256));
        assertEq(rootAccount, address(acc));
        assertEq(rootId, id1);
    }

    function testHeap_empty_after_all_processed() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("single", 1, 1, 1, 1, address(0x1), 0);

        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);

        vm.prank(address(this));
        tm.performUpkeep(data);

        // Heap should be empty now
        (bool needed2,) = tm.checkUpkeep("");
        assertFalse(needed2);
    }

    /*///////////////////////////////////////////////////////////////
                    STATUS ARRAY EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function testStatusArrays_pagination_edge_cases() public {
        // Test pagination with start >= total
        ITaskManager.Task[] memory emptyResult =
            tm.getTasksByStatus(address(acc), ITaskManager.TaskStatus.PENDING, 100, 10);
        assertEq(emptyResult.length, 0);

        // Test with limit = 0
        ITaskManager.Task[] memory zeroLimit = tm.getTasksByStatus(address(acc), ITaskManager.TaskStatus.PENDING, 0, 0);
        assertEq(zeroLimit.length, 0);

        // Create some tasks and test boundary pagination
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(acc));
            tm.createTask("test", 1, 1 days + i, 1, 1, address(0x1), 0);
        }

        // Test start at last element
        ITaskManager.Task[] memory lastElement =
            tm.getTasksByStatus(address(acc), ITaskManager.TaskStatus.PENDING, 4, 10);
        assertEq(lastElement.length, 1);

        // Test limit exceeding remaining
        ITaskManager.Task[] memory exceedingLimit =
            tm.getTasksByStatus(address(acc), ITaskManager.TaskStatus.PENDING, 3, 10);
        assertEq(exceedingLimit.length, 2); // only 2 remaining from index 3
    }

    function testTaskCountsByStatus_comprehensive() public {
        // Create tasks in different statuses
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("pending1", 1, 1 days, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        uint256 id2 = tm.createTask("pending2", 1, 1 days, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        uint256 id3 = tm.createTask("to_complete", 1, 1 days, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        uint256 id4 = tm.createTask("to_cancel", 1, 1 days, 1, 1, address(0x1), 0);

        // Complete and cancel some
        vm.prank(address(acc));
        tm.completeTask(id3);

        vm.prank(address(acc));
        tm.cancelTask(id4);

        uint256[] memory counts = tm.getTaskCountsByStatus(address(acc));

        // Check counts: PENDING=2, COMPLETED=1, CANCELED=1, EXPIRED=0
        assertEq(counts[uint8(ITaskManager.TaskStatus.PENDING)], 2);
        assertEq(counts[uint8(ITaskManager.TaskStatus.COMPLETED)], 1);
        assertEq(counts[uint8(ITaskManager.TaskStatus.CANCELED)], 1);
        assertEq(counts[uint8(ITaskManager.TaskStatus.EXPIRED)], 0);
    }

    /*///////////////////////////////////////////////////////////////
                    DELAYED PAYMENT COMPREHENSIVE
    ///////////////////////////////////////////////////////////////*/

    function testDelayedPayment_full_lifecycle() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("delayed_test", 1, 5, 1, 10, address(0x1), 0); // expire in 5s, delay 10s

        // Check task is pending
        ITaskManager.Task memory task = tm.getTask(address(acc), id);
        assertEq(uint8(task.status), uint8(ITaskManager.TaskStatus.PENDING));
        assertFalse(task.delayedRewardReleased);

        // Expire the task
        vm.warp(block.timestamp + 7);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        vm.prank(address(this));
        tm.performUpkeep(data);

        // Task should now be expired
        task = tm.getTask(address(acc), id);
        assertEq(uint8(task.status), uint8(ITaskManager.TaskStatus.EXPIRED));

        // Try to release before delay period - should revert in SmartAccount
        // (We can't test this directly from TaskManager, but the flow would fail)

        // Release delayed payment after expiry
        vm.prank(address(acc));
        tm.releaseDelayedPayment(id);

        // Check flag is set
        task = tm.getTask(address(acc), id);
        assertTrue(task.delayedRewardReleased);
    }

    function testDelayedPayment_wrong_choice_reverts() public {
        // Create SENDBUDDY task (choice=2) and try delayed payment release
        vm.prank(address(acc));
        uint256 id = tm.createTask("sendbuddy", 1, 1, 2, 0, alice, 0);

        // Expire it
        vm.warp(block.timestamp + 5);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        vm.prank(address(this));
        tm.performUpkeep(data);

        // Try to release delayed payment on non-delayed task
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__InvalidPenaltyConfig.selector);
        tm.releaseDelayedPayment(id);
    }

    /*///////////////////////////////////////////////////////////////
                    AUTOMATION INTERFACE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testCheckUpkeep_empty_heap() public view {
        // No tasks created, heap is empty
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertFalse(needed);
        assertEq(data.length, 0);
    }

    function testPerformUpkeep_stale_data() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("test", 1, 5, 1, 1, address(0x1), 0);

        // Get upkeep data
        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);

        // Complete the task before performUpkeep
        vm.prank(address(acc));
        tm.completeTask(id);

        // Now call performUpkeep with stale data - should handle gracefully
        vm.prank(address(this));
        tm.performUpkeep(data); // Should not revert, just return early
    }

    function testPerformUpkeep_wrong_root() public {
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("first", 1, 5, 1, 1, address(0x1), 0);

        vm.prank(address(acc));
        uint256 id2 = tm.createTask("second", 1, 10, 1, 1, address(0x1), 0);

        vm.warp(block.timestamp + 15);

        // Create wrong performData
        bytes memory wrongData = abi.encode(address(acc), id2); // id2 is not the root

        vm.prank(address(this));
        tm.performUpkeep(wrongData); // Should handle gracefully and not process

        // id1 should still be pending (not processed)
        ITaskManager.Task memory task = tm.getTask(address(acc), id1);
        assertEq(uint8(task.status), uint8(ITaskManager.TaskStatus.PENDING));
    }

    /*///////////////////////////////////////////////////////////////
                    INTERFACE COMPLIANCE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testSupportsInterface_comprehensive() public view {
        // Test specific interface IDs
        assertTrue(tm.supportsInterface(type(ITaskManager).interfaceId));
        assertTrue(tm.supportsInterface(type(AutomationCompatibleInterface).interfaceId));
        assertTrue(tm.supportsInterface(type(IERC165).interfaceId));

        // Test invalid interface
        assertFalse(tm.supportsInterface(bytes4(0xffffffff)));
    }

    /*///////////////////////////////////////////////////////////////
                    TASK STATE VALIDATION
    ///////////////////////////////////////////////////////////////*/

    function testTaskExist_modifier() public {
        // Try to get non-existent task
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        tm.getTask(address(acc), 999);

        // Try operations on non-existent task
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        tm.completeTask(999);

        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        tm.cancelTask(999);

        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskDoesntExist.selector);
        tm.releaseDelayedPayment(999);
    }

    /*///////////////////////////////////////////////////////////////
                    CONCURRENT TASK OPERATIONS
    ///////////////////////////////////////////////////////////////*/

    function testConcurrentTasks_different_accounts() public {
        MockAccountSuccess acc2 = new MockAccountSuccess(tm);

        // Both accounts create tasks simultaneously
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("acc1_task", 1 ether, 1 days, 1, 1 hours, address(0x1), 0);

        vm.prank(address(acc2));
        uint256 id2 = tm.createTask("acc2_task", 2 ether, 2 days, 2, 0, alice, 0);

        // Verify isolation - each account has its own task counter starting from 0
        assertEq(id1, 0);
        assertEq(id2, 0);

        // Verify task counts
        assertEq(tm.getTotalTasks(address(acc)), 1);
        assertEq(tm.getTotalTasks(address(acc2)), 1);

        // Verify tasks are independent
        ITaskManager.Task memory task1 = tm.getTask(address(acc), 0);
        ITaskManager.Task memory task2 = tm.getTask(address(acc2), 0);

        assertEq(task1.rewardAmount, 1 ether);
        assertEq(task2.rewardAmount, 2 ether);
    }

    function testTaskStatusTransitions_comprehensive() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("status_test", 1, 1 days, 1, 1 hours, address(0x1), 0);

        // Initial state: PENDING
        uint256[] memory initialCounts = tm.getTaskCountsByStatus(address(acc));
        assertEq(initialCounts[uint8(ITaskManager.TaskStatus.PENDING)], 1);
        assertEq(initialCounts[uint8(ITaskManager.TaskStatus.COMPLETED)], 0);
        assertEq(initialCounts[uint8(ITaskManager.TaskStatus.CANCELED)], 0);
        assertEq(initialCounts[uint8(ITaskManager.TaskStatus.EXPIRED)], 0);

        // Complete task
        vm.prank(address(acc));
        tm.completeTask(id);

        uint256[] memory completedCounts = tm.getTaskCountsByStatus(address(acc));
        assertEq(completedCounts[uint8(ITaskManager.TaskStatus.PENDING)], 0);
        assertEq(completedCounts[uint8(ITaskManager.TaskStatus.COMPLETED)], 1);

        // Create another and cancel
        vm.prank(address(acc));
        uint256 id2 = tm.createTask("cancel_test", 1, 1 days, 1, 1 hours, address(0x1), 0);

        vm.prank(address(acc));
        tm.cancelTask(id2);

        uint256[] memory mixedCounts = tm.getTaskCountsByStatus(address(acc));
        assertEq(mixedCounts[uint8(ITaskManager.TaskStatus.PENDING)], 0);
        assertEq(mixedCounts[uint8(ITaskManager.TaskStatus.COMPLETED)], 1);
        assertEq(mixedCounts[uint8(ITaskManager.TaskStatus.CANCELED)], 1);
    }

    /*///////////////////////////////////////////////////////////////
                    HEAP CORRUPTION PREVENTION
    ///////////////////////////////////////////////////////////////*/

    function testHeap_large_dataset_integrity() public {
        // Create many tasks to stress test heap
        uint256[] memory taskIds = new uint256[](10);
        uint256[] memory deadlines = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            deadlines[i] = block.timestamp + (i * 10) + 1; // stagger deadlines
            vm.prank(address(acc));
            taskIds[i] = tm.createTask(string(abi.encodePacked("task_", i)), 1, (i * 10) + 1, 1, 1, address(0x1), 0);
        }

        // Cancel some tasks randomly to test heap removal
        vm.prank(address(acc));
        tm.cancelTask(taskIds[3]);

        vm.prank(address(acc));
        tm.cancelTask(taskIds[7]);

        vm.prank(address(acc));
        tm.cancelTask(taskIds[1]);

        // Process remaining tasks in order and verify heap maintains order
        for (uint256 i = 0; i < 10; i++) {
            if (i == 1 || i == 3 || i == 7) continue; // cancelled tasks

            vm.warp(deadlines[i] + 1);
            (bool needed, bytes memory data) = tm.checkUpkeep("");

            if (needed) {
                (address rootAccount, uint256 rootId) = abi.decode(data, (address, uint256));
                assertEq(rootAccount, address(acc));
                assertEq(rootId, taskIds[i]);

                vm.prank(address(this));
                tm.performUpkeep(data);
            }
        }
    }

    /*///////////////////////////////////////////////////////////////
                    ERROR CONDITION COMPREHENSIVE
    ///////////////////////////////////////////////////////////////*/

    function testReleaseDelayedPayment_double_release() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("double", 1, 1, 1, 1, address(0x1), 0);

        // Expire
        vm.warp(block.timestamp + 5);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        vm.prank(address(this));
        tm.performUpkeep(data);

        // First release
        vm.prank(address(acc));
        tm.releaseDelayedPayment(id);

        // Second release should fail
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__AlreadyReleased.selector);
        tm.releaseDelayedPayment(id);
    }

    function testTaskOperations_on_expired_tasks() public {
        vm.prank(address(acc));
        uint256 id = tm.createTask("expire_test", 1, 1, 1, 1, address(0x1), 0);

        // Expire the task
        vm.warp(block.timestamp + 5);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        vm.prank(address(this));
        tm.performUpkeep(data);

        // Try to complete expired task
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskIsNotPending.selector);
        tm.completeTask(id);

        // Try to cancel expired task
        vm.prank(address(acc));
        vm.expectRevert(TaskManager.TaskManager__TaskIsNotPending.selector);
        tm.cancelTask(id);
    }

    /*///////////////////////////////////////////////////////////////
                    BOUNDARY VALUE TESTS
    ///////////////////////////////////////////////////////////////*/

    function testCreateTask_boundary_values() public {
        // Test with very large reward amount
        vm.prank(address(acc));
        uint256 id1 = tm.createTask("large_reward", type(uint256).max, 1 days, 1, 1, address(0x1), 0);

        ITaskManager.Task memory task = tm.getTask(address(acc), id1);
        assertEq(task.rewardAmount, type(uint256).max);

        // Test with minimum valid values
        vm.prank(address(acc));
        uint256 id2 = tm.createTask("min_values", 1, 1, 1, 1, address(0x1), 0);

        task = tm.getTask(address(acc), id2);
        assertEq(task.rewardAmount, 1);
        assertEq(task.delayDuration, 1);
    }

    function testCreateTask_verification_method_values() public {
        // Test all valid verification method values (0, 1, 2)
        for (uint8 method = 0; method <= 2; method++) {
            vm.prank(address(acc));
            uint256 id = tm.createTask("verify_test", 1, 1 days, 1, 1, address(0x1), method);

            ITaskManager.Task memory task = tm.getTask(address(acc), id);
            assertEq(uint8(task.verificationMethod), method);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    GAS OPTIMIZATION TESTS
    ///////////////////////////////////////////////////////////////*/

    function testGasUsage_multiple_operations() public {
        // Measure gas for creating multiple tasks
        uint256 gasBefore = gasleft();

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(acc));
            tm.createTask("gas_test", 1, 1 days + i, 1, 1, address(0x1), 0);
        }

        uint256 gasUsed = gasBefore - gasleft();
        // Basic assertion that gas usage is reasonable (allow a higher budget on CI)
        assertTrue(gasUsed < 2000000); // Less than 2M gas for 5 tasks
    }

    /*///////////////////////////////////////////////////////////////
                    TASK DESCRIPTION EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function testCreateTask_long_description() public {
        // Test with very long description
        string memory longDesc = "";
        for (uint256 i = 0; i < 100; i++) {
            longDesc = string(abi.encodePacked(longDesc, "very long description "));
        }

        vm.prank(address(acc));
        uint256 id = tm.createTask(longDesc, 1 ether, 1 days, 1, 1, address(0x1), 0);

        ITaskManager.Task memory task = tm.getTask(address(acc), id);
        assertEq(keccak256(bytes(task.description)), keccak256(bytes(longDesc)));
    }

    function testCreateTask_special_characters_description() public {
        string memory specialDesc = unicode"Task with 特殊字符 and émojis 🎯 and newlines\n\tand tabs";

        vm.prank(address(acc));
        uint256 id = tm.createTask(specialDesc, 1 ether, 1 days, 1, 1, address(0x1), 0);

        ITaskManager.Task memory task = tm.getTask(address(acc), id);
        assertEq(keccak256(bytes(task.description)), keccak256(bytes(specialDesc)));
    }

    /*///////////////////////////////////////////////////////////////
                    REENTRANCY PROTECTION TESTS
    ///////////////////////////////////////////////////////////////*/

    function testReentrancy_protection_all_functions() public {
        // Test that all external functions with nonReentrant work correctly
        ReentrantTaskManager attacker = new ReentrantTaskManager(tm);

        // The attacker will create a task; when performUpkeep is called later it
        // will invoke the attacker's expiredTaskCallback which attempts to call
        // back into TaskManager. That nested call should be blocked by
        // ReentrancyGuard on performUpkeep.
        attacker.attackCreateTask();

        // advance time so the task is expired and performUpkeep will call back
        vm.warp(block.timestamp + 10);

        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);

        // performUpkeep will catch the revert from the nested createTask and emit TaskExpiredCallFailure
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit TaskManager.TaskExpiredCallFailure(address(attacker), 0);
        tm.performUpkeep(data);
    }

    /*///////////////////////////////////////////////////////////////
                            PAGINATION & COUNTS
    ///////////////////////////////////////////////////////////////*/

    function testGetTasksByStatus_pagination_and_counts() public {
        // create 5 pending tasks
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(acc));
            tm.createTask("p", 1, 100 + i, 1, 1, address(0x1), 0);
        }

        // total tasks
        uint256 total = tm.getTotalTasks(address(acc));
        assertEq(total, 5);

        // counts by status (only pending)
        uint256[] memory counts = tm.getTaskCountsByStatus(address(acc));
        // index 0 == PENDING
        assertEq(counts[uint256(uint8(ITaskManager.TaskStatus.PENDING))], 5);

        // page 0..1 (limit 2)
        ITaskManager.Task[] memory page = tm.getTasksByStatus(address(acc), ITaskManager.TaskStatus.PENDING, 0, 2);
        assertEq(page.length, 2);

        // start beyond total returns empty
        ITaskManager.Task[] memory emptyPage = tm.getTasksByStatus(address(acc), ITaskManager.TaskStatus.PENDING, 10, 2);
        assertEq(emptyPage.length, 0);
    }

    /*///////////////////////////////////////////////////////////////
                            SUPPORTS INTERFACE
    ///////////////////////////////////////////////////////////////*/

    function testSupportsInterface() public view {
        bool s1 = tm.supportsInterface(type(ITaskManager).interfaceId);
        bool s2 = tm.supportsInterface(type(AutomationCompatibleInterface).interfaceId);
        bool s3 = tm.supportsInterface(type(IERC165).interfaceId);

        assertTrue(s1 && s2 && s3);
    }

    /*///////////////////////////////////////////////////////////////
                            EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function testHeapRemoval_middleItem_behaviour() public {
        // Create three tasks with deadlines: 3,5,7 seconds
        vm.prank(address(acc));
        uint256 a0 = tm.createTask("a", 1, 3, 1, 1, address(0x1), 0);
        vm.prank(address(acc));
        uint256 a1 = tm.createTask("b", 1, 5, 1, 1, address(0x1), 0);
        vm.prank(address(acc));
        uint256 a2 = tm.createTask("c", 1, 7, 1, 1, address(0x1), 0);

        // cancel middle (deadline 5)
        vm.prank(address(acc));
        tm.cancelTask(a1);

        // warp past earliest (3) and run upkeep - should process a0
        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        vm.prank(address(this));
        tm.performUpkeep(data);

        // Next upkeep should process a2 (deadline 7)
        // Re-check checkUpkeep now; it should still be true with next root corresponding to a2
        (bool needed2, bytes memory data2) = tm.checkUpkeep("");
        assertTrue(needed2);
        (address rootAccount, uint256 rootId) = abi.decode(data2, (address, uint256));
        assertEq(rootAccount, address(acc));
        assertEq(rootId, a2);
    }
}
/*///////////////////////////////////////////////////////////////
                    HELPER CONTRACTS FOR ADVANCED TESTS
///////////////////////////////////////////////////////////////*/

contract ReentrantTaskManager {
    TaskManager public tm;
    bool public attacking;

    constructor(TaskManager _tm) {
        tm = _tm;
    }

    function attackCreateTask() external {
        attacking = true;
        // Create a task that will, during TaskManager.performUpkeep, call back into
        // this contract. The callback will then try to create another task, causing
        // a reentrant call to TaskManager.createTask.
        tm.createTask("attack", 1, 1, 1, 1, address(0x1), 0);
    }

    // This will be called during the first createTask and try to create another
    function expiredTaskCallback(uint256) external {
        if (attacking) {
            // This nested createTask should hit the nonReentrant guard in TaskManager
            tm.createTask("reentrant", 1, 1, 1, 1, address(0x1), 0);
        }
    }

    // Required interface implementations
    function validateUserOp(UserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function execute(address, uint256, bytes calldata) external {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}
