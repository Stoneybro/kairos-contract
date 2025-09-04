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
    function expiredTaskCallback(uint256) external override {
        revert("callback revert");
    }

    // stubs for IAccount
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
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
        vm.expectRevert(TaskManager.TaskManager__TaskHasBeenCanceled.selector);
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

    function testSupportsInterface() public {
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
