// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {SmartAccount} from "src/SmartAccount.sol";
import {TaskManager} from "src/TaskManager.sol";
import {ITaskManager} from "src/interface/ITaskManager.sol";
import {ISmartAccount} from "src/interface/ISmartAccount.sol";
import {UserOperation} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// Mock EntryPoint for testing
contract MockEntryPoint {
    function handleOps(UserOperation[] calldata, address payable) external {}
}

contract SmartAccountTest is Test {
    SmartAccount public smartAccount;
    TaskManager public taskManager;
    MockEntryPoint public entryPoint;

    address public owner;
    uint256 public ownerPrivateKey;
    address public buddy;
    address public user;

    uint8 constant PENALTY_DELAYEDPAYMENT = 1;
    uint8 constant PENALTY_SENDBUDDY = 2;

    uint256 constant INITIAL_BALANCE = 10 ether;
    uint256 constant REWARD_AMOUNT = 1 ether;
    uint256 constant DEADLINE_SECONDS = 3600; // 1 hour
    uint256 constant DELAY_DURATION = 86400; // 1 day

    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event DurationPenaltyApplied(uint256 indexed taskId, uint256 indexed penaltyDuration);
    event DelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);
    event PenaltyFundsReleasedToBuddy(uint256 indexed taskId, uint256 indexed rewardAmount, address indexed buddy);
    event Transferred(address indexed to, uint256 amount);

    function setUp() public {
        // Create test accounts
        ownerPrivateKey = 0x12341234;
        owner = vm.addr(ownerPrivateKey);
        buddy = makeAddr("buddy");
        user = makeAddr("user");

        // Deploy contracts
        entryPoint = new MockEntryPoint();
        taskManager = new TaskManager();
        smartAccount = new SmartAccount();

        // Initialize SmartAccount
        smartAccount.initialize(owner, address(entryPoint), taskManager);

        // Fund the smart account
        vm.deal(address(smartAccount), INITIAL_BALANCE);

        // Set up pranks
        vm.label(owner, "Owner");
        vm.label(buddy, "Buddy");
        vm.label(address(smartAccount), "SmartAccount");
        vm.label(address(taskManager), "TaskManager");
    }

    // ==================== INITIALIZATION TESTS ====================

    function test_Initialize() public {
        SmartAccount newAccount = new SmartAccount();
        newAccount.initialize(owner, address(entryPoint), taskManager);

        assertEq(newAccount.s_owner(), owner);
        assertEq(address(newAccount.taskManager()), address(taskManager));
        assertEq(newAccount.s_totalCommittedReward(), 0);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert();
        smartAccount.initialize(owner, address(entryPoint), taskManager);
    }

    // ==================== TASK CREATION TESTS ====================

    function test_CreateTaskWithDelayedPaymentPenalty() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TaskCreated(0, "Test Task", REWARD_AMOUNT);

        smartAccount.createTask(
            "Test Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        assertEq(smartAccount.s_totalCommittedReward(), REWARD_AMOUNT);

        ITaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(task.id, 0);
        assertEq(task.description, "Test Task");
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        assertEq(task.choice, PENALTY_DELAYEDPAYMENT);
        assertEq(task.delayDuration, DELAY_DURATION);
        assertTrue(task.status == ITaskManager.TaskStatus.PENDING);
    }

    function test_CreateTaskWithBuddyPenalty() public {
        vm.prank(owner);
        smartAccount.createTask("Buddy Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);

        ITaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(task.choice, PENALTY_SENDBUDDY);
        assertEq(task.buddy, buddy);
        assertEq(task.delayDuration, 0);
    }

    function test_CreateTaskFailsWithInsufficientFunds() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__AddMoreFunds.selector);
        smartAccount.createTask(
            "Expensive Task", INITIAL_BALANCE + 1, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
    }

    function test_CreateTaskFailsWithZeroReward() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__RewardCannotBeZero.selector);
        smartAccount.createTask(
            "Zero Reward Task", 0, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
    }

    function test_CreateTaskFailsWithInvalidPenaltyChoice() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PickAPenalty.selector);
        smartAccount.createTask(
            "Invalid Choice Task",
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            0, // Invalid choice
            address(0),
            DELAY_DURATION
        );

        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyChoice.selector);
        smartAccount.createTask(
            "Invalid Choice Task",
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            3, // Invalid choice (> 2)
            address(0),
            DELAY_DURATION
        );
    }

    function test_CreateTaskFailsWithInvalidBuddyConfig() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        smartAccount.createTask(
            "Buddy Task",
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            PENALTY_SENDBUDDY,
            address(0), // No buddy address
            0
        );
    }

    function test_CreateTaskFailsWithInvalidDelayConfig() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        smartAccount.createTask(
            "Delay Task",
            REWARD_AMOUNT,
            DEADLINE_SECONDS,
            PENALTY_DELAYEDPAYMENT,
            address(0),
            0 // No delay duration
        );
    }

    function test_CreateTaskFailsFromNonOwner() public {
        vm.prank(user);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.createTask(
            "Unauthorized Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
    }

    // ==================== TASK COMPLETION TESTS ====================

    function test_CompleteTask() public {
        // Create task first
        vm.prank(owner);
        smartAccount.createTask(
            "Complete Me", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        uint256 ownerBalanceBefore = owner.balance;

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit TaskCompleted(0);

        smartAccount.completeTask(0);

        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(owner.balance, ownerBalanceBefore + REWARD_AMOUNT);

        ITaskManager.Task memory task = smartAccount.getTask(0);
        assertTrue(task.status == ITaskManager.TaskStatus.COMPLETED);
    }

    function test_CompleteTaskFailsIfAlreadyCompleted() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Complete Me", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        vm.prank(owner);
        smartAccount.completeTask(0);

        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCompleted.selector);
        smartAccount.completeTask(0);
    }

    function test_CompleteTaskFailsFromNonOwner() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Complete Me", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        vm.prank(user);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.completeTask(0);
    }

    // ==================== TASK CANCELLATION TESTS ====================

    function test_CancelTask() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Cancel Me", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        assertEq(smartAccount.s_totalCommittedReward(), REWARD_AMOUNT);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit TaskCanceled(0);

        smartAccount.cancelTask(0);

        assertEq(smartAccount.s_totalCommittedReward(), 0);

        ITaskManager.Task memory task = smartAccount.getTask(0);
        assertTrue(task.status == ITaskManager.TaskStatus.CANCELED);
    }

    function test_CancelTaskFailsFromNonOwner() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Cancel Me", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        vm.prank(user);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.cancelTask(0);
    }

    // ==================== TASK EXPIRATION TESTS ====================

    function test_ExpiredTaskCallbackWithDelayedPayment() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Delayed Payment Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Expire the task via TaskManager
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }

        // Fast forward past delay duration
        vm.warp(block.timestamp + DELAY_DURATION + 1);

        uint256 ownerBalanceBefore = owner.balance;

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit DelayedPaymentReleased(0, REWARD_AMOUNT);

        smartAccount.releaseDelayedPayment(0);

        assertEq(owner.balance, ownerBalanceBefore + REWARD_AMOUNT);
        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    function test_ExpiredTaskCallbackWithBuddyPenalty() public {
        vm.prank(owner);
        smartAccount.createTask("Buddy Penalty Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);

        uint256 buddyBalanceBefore = buddy.balance;

        // Fast forward time past the deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Expect the event from the SmartAccount callback
        vm.expectEmit(true, true, true, false);
        emit PenaltyFundsReleasedToBuddy(0, REWARD_AMOUNT, buddy);

        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }

        // Verify the results
        assertEq(buddy.balance, buddyBalanceBefore + REWARD_AMOUNT, "Buddy did not receive reward");
        assertEq(smartAccount.s_totalCommittedReward(), 0, "Committed reward was not cleared");
    }

    function test_ExpiredTaskCallbackFailsFromNonTaskManager() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Expire Me", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        vm.prank(user);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyTaskManagerCanCall.selector);
        smartAccount.expiredTaskCallback(0);
    }

    // ==================== DELAYED PAYMENT RELEASE TESTS ====================

    function test_ReleaseDelayedPayment() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Delayed Payment Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Expire the task via TaskManager
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }

        // Fast forward past delay duration
        vm.warp(block.timestamp + DELAY_DURATION + 1);

        uint256 ownerBalanceBefore = owner.balance;

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit DelayedPaymentReleased(0, REWARD_AMOUNT);

        smartAccount.releaseDelayedPayment(0);

        assertEq(owner.balance, ownerBalanceBefore + REWARD_AMOUNT);
        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    function test_ReleaseDelayedPaymentFailsBeforeDelayElapsed() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Delayed Payment Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Expire the task via TaskManager
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }

        // Do NOT warp past delay duration
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyDurationNotElapsed.selector);
        smartAccount.releaseDelayedPayment(0);
    }

    // ==================== TRANSFER TESTS ====================

    function test_Transfer() public {
        address recipient = makeAddr("recipient");
        uint256 transferAmount = 1 ether;
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Transferred(recipient, transferAmount);

        smartAccount.transfer(recipient, transferAmount);

        assertEq(recipient.balance, recipientBalanceBefore + transferAmount);
    }

    function test_TransferFailsWithCommittedRewards() public {
        // Create a task to commit some rewards
        vm.prank(owner);
        smartAccount.createTask(
            "Committed Task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        address recipient = makeAddr("recipient");
        uint256 availableBalance = INITIAL_BALANCE - REWARD_AMOUNT;

        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__CannotWithdrawCommittedRewards.selector);
        smartAccount.transfer(recipient, availableBalance + 1);
    }

    function test_TransferFailsWithZeroAmount() public {
        address recipient = makeAddr("recipient");

        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__CannotTransferZero.selector);
        smartAccount.transfer(recipient, 0);
    }

    function test_TransferFailsFromNonOwner() public {
        address recipient = makeAddr("recipient");

        vm.prank(user);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.transfer(recipient, 1 ether);
    }

    // ==================== SIGNATURE VALIDATION TESTS ====================

    function test_ValidateUserOpWithValidSignature() public {
        UserOperation memory userOp = UserOperation({
            sender: address(smartAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 0,
            verificationGasLimit: 150000,
            preVerificationGas: 21000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedMessageHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(address(entryPoint));
        uint256 validationData = smartAccount.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, _packValidationData(false, 0, 0));
    }

    function test_ValidateUserOpWithInvalidSignature() public {
        UserOperation memory userOp = UserOperation({
            sender: address(smartAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 0,
            verificationGasLimit: 150000,
            preVerificationGas: 21000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: "",
            signature: new bytes(65) // 65 zero bytes, which is invalid for ECDSA
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));

        vm.prank(address(entryPoint));
        vm.expectRevert(); // ECDSA.recover will revert
        smartAccount.validateUserOp(userOp, userOpHash, 0);
    }

    // ==================== EXECUTE TESTS ====================

    function test_Execute() public {
        address target = makeAddr("target");
        vm.deal(target, 0);

        bytes memory callData = abi.encodeWithSignature("someFunction()");

        vm.prank(address(entryPoint));
        smartAccount.execute(target, 1 ether, callData);

        assertEq(target.balance, 1 ether);
    }

    function test_ExecuteFailsFromNonEntryPoint() public {
        address target = makeAddr("target");
        bytes memory callData = abi.encodeWithSignature("someFunction()");

        vm.prank(user);
        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        smartAccount.execute(target, 1 ether, callData);
    }

    // ==================== VIEW FUNCTION TESTS ====================

    function test_GetTotalTasks() public {
        assertEq(smartAccount.getTotalTasks(), 0);

        vm.prank(owner);
        smartAccount.createTask(
            "Task 1", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        assertEq(smartAccount.getTotalTasks(), 1);
    }

    function test_GetAllTasks() public {
        // Create multiple tasks
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(owner);
            smartAccount.createTask(
                string(abi.encodePacked("Task ", vm.toString(i))),
                REWARD_AMOUNT,
                DEADLINE_SECONDS,
                PENALTY_DELAYEDPAYMENT,
                address(0),
                DELAY_DURATION
            );
        }

        ITaskManager.Task[] memory tasks = smartAccount.getAllTasks();

        assertEq(tasks.length, 3);
        assertEq(tasks[0].id, 0);
        assertEq(tasks[1].id, 1);
        assertEq(tasks[2].id, 2);
    }

    function test_SupportsInterface() public {
        assertTrue(smartAccount.supportsInterface(type(ISmartAccount).interfaceId));
        assertTrue(smartAccount.supportsInterface(type(IERC165).interfaceId));
        assertFalse(smartAccount.supportsInterface(bytes4(0x12345678)));
    }

    // ==================== EDGE CASE TESTS ====================

    function test_MultipleTasksCommittedRewards() public {
        uint256 task1Reward = 2 ether;
        uint256 task2Reward = 3 ether;

        vm.prank(owner);
        smartAccount.createTask(
            "Task 1", task1Reward, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        vm.prank(owner);
        smartAccount.createTask("Task 2", task2Reward, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);

        assertEq(smartAccount.s_totalCommittedReward(), task1Reward + task2Reward);

        // Complete first task
        vm.prank(owner);
        smartAccount.completeTask(0);

        assertEq(smartAccount.s_totalCommittedReward(), task2Reward);

        // Cancel second task
        vm.prank(owner);
        smartAccount.cancelTask(1);

        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    function test_ReceiveFallback() public {
        uint256 balanceBefore = address(smartAccount).balance;

        // Test receive function
        (bool success,) = address(smartAccount).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(smartAccount).balance, balanceBefore + 1 ether);

        // Test fallback function
        (success,) = address(smartAccount).call{value: 1 ether}("0x1234");
        assertTrue(success);
        assertEq(address(smartAccount).balance, balanceBefore + 2 ether);
    }

    // ==================== FUZZ TESTS ====================

    function testFuzz_CreateTaskWithDifferentRewards(uint256 rewardAmount) public {
        vm.assume(rewardAmount > 0 && rewardAmount <= INITIAL_BALANCE);

        vm.prank(owner);
        smartAccount.createTask(
            "Fuzz Task", rewardAmount, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        assertEq(smartAccount.s_totalCommittedReward(), rewardAmount);
    }

    function testFuzz_TransferDifferentAmounts(uint256 transferAmount) public {
        vm.assume(transferAmount > 0 && transferAmount <= INITIAL_BALANCE);

        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(owner);
        smartAccount.transfer(recipient, transferAmount);

        assertEq(recipient.balance, recipientBalanceBefore + transferAmount);
    }

    function test_OnlyOwnerCanCall() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.transfer(makeAddr("recipient"), 1 ether);
    }

    function test_AddMoreFunds() public {
        vm.prank(owner);
        uint256 excessiveReward = INITIAL_BALANCE + 1 ether;
        vm.expectRevert(SmartAccount.SmartAccount__AddMoreFunds.selector);
        smartAccount.createTask(
            "Too Expensive", excessiveReward, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
    }

    function test_InvalidPenaltyChoice() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyChoice.selector);
        smartAccount.createTask("Invalid Penalty", 1 ether, DEADLINE_SECONDS, 3, address(0), DELAY_DURATION);
    }

    function test_PickAPenalty() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PickAPenalty.selector);
        smartAccount.createTask("No Penalty", 1 ether, DEADLINE_SECONDS, 0, address(0), DELAY_DURATION);
    }

    function test_CannotWithdrawCommittedRewards() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Commit Funds", 9 ether, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__CannotWithdrawCommittedRewards.selector);
        smartAccount.transfer(makeAddr("recipient"), 2 ether);
    }

    function test_TaskAlreadyCompleted() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Complete Me", 1 ether, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.prank(owner);
        smartAccount.completeTask(0);
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCompleted.selector);
        smartAccount.completeTask(0);
    }

    function test_PenaltyDurationNotElapsed() public {
        vm.prank(owner);
        smartAccount.createTask(
            "Delayed", 1 ether, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyDurationNotElapsed.selector);
        smartAccount.releaseDelayedPayment(0);
    }
}
