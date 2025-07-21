// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {SmartAccount} from "src/SmartAccount.sol";
import {TaskManager} from "src/TaskManager.sol";
import {AccountFactory} from "src/AccountFactory.sol";
import {DeployAccountFactory} from "script/DeployAccountFactory.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {PackedUserOperation} from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract SmartAccountTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/
    SmartAccount public smartAccount;
    TaskManager public taskManager;
    AccountFactory public accountFactory;
    HelperConfig public helperConfig;
    address public owner;
    uint256 public ownerPrivateKey;
    address public buddy;
    address public entryPoint;

    uint256 constant INITIAL_BALANCE = 10 ether;
    uint256 constant REWARD_AMOUNT = 1 ether;
    uint256 constant DEADLINE_SECONDS = 3600; // 1 hour
    uint256 constant DELAY_DURATION = 1800; // 30 minutes

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
                                 SETUP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        // Setup accounts
        ownerPrivateKey = 0x123;
        owner = vm.addr(ownerPrivateKey);
        buddy = makeAddr("buddy");
        DeployAccountFactory deploy = new DeployAccountFactory();
        helperConfig= new HelperConfig();
        HelperConfig.NetworkConfig memory networkConfig = helperConfig.getConfig();
        entryPoint = networkConfig.entryPoint;
        // Deploy contracts
        (accountFactory) = deploy.deployFactory(entryPoint,owner);

        vm.startPrank(owner);
        address accountAddress = accountFactory.createAccount(0);
        smartAccount = SmartAccount(payable(accountAddress));
        taskManager = TaskManager(smartAccount.getTaskManagerAddress());
        vm.stopPrank();

        // Fund the account
        vm.deal(address(smartAccount), INITIAL_BALANCE);

        // Labels for better debugging
        vm.label(address(smartAccount), "SmartAccount");
        vm.label(address(taskManager), "TaskManager");
        vm.label(owner, "Owner");
        vm.label(buddy, "Buddy");
        vm.label(entryPoint, "EntryPoint");
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Initialize() public view {
        assertEq(smartAccount.s_owner(), owner);
        assertEq(address(smartAccount.taskManager()), address(taskManager));
        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_ReceiveEther() public {
        uint256 initialBalance = address(smartAccount).balance;
        uint256 sendAmount = 1 ether;

        (bool success,) = payable(address(smartAccount)).call{value: sendAmount}("");
        assertTrue(success);
        assertEq(address(smartAccount).balance, initialBalance + sendAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           TASK CREATION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_CreateTaskWithDelayedPayment() public {
        vm.startPrank(owner);

        vm.expectEmit(true, false, false, true);
        emit TaskCreated(0, "Test task", REWARD_AMOUNT);

        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        TaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(task.description, "Test task");
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        assertEq(task.choice, PENALTY_DELAYEDPAYMENT);
        assertEq(task.delayDuration, DELAY_DURATION);
        assertTrue(task.valid);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.PENDING));

        assertEq(smartAccount.s_totalCommittedReward(), REWARD_AMOUNT);
        vm.stopPrank();
    }

    function test_CreateTaskWithBuddyPenalty() public {
        vm.startPrank(owner);

        smartAccount.createTask("Test task with buddy", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);

        TaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(task.buddy, buddy);
        assertEq(task.choice, PENALTY_SENDBUDDY);
        vm.stopPrank();
    }

    function test_RevertCreateTask_OnlyOwner() public {
        vm.prank(buddy);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.createTask(
            "Test", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
    }

    function test_RevertCreateTask_InsufficientFunds() public {
        vm.startPrank(owner);
        uint256 excessiveReward = INITIAL_BALANCE + 1 ether;

        vm.expectRevert(SmartAccount.SmartAccount__AddMoreFunds.selector);
        smartAccount.createTask(
            "Test", excessiveReward, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.stopPrank();
    }

    function test_RevertCreateTask_ZeroReward() public {
        vm.startPrank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__RewardCannotBeZero.selector);
        smartAccount.createTask("Test", 0, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION);
        vm.stopPrank();
    }

    function test_RevertCreateTask_NoPenaltyChoice() public {
        vm.startPrank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PickAPenalty.selector);
        smartAccount.createTask("Test", REWARD_AMOUNT, DEADLINE_SECONDS, 0, address(0), DELAY_DURATION);
        vm.stopPrank();
    }

    function test_RevertCreateTask_InvalidPenaltyChoice() public {
        vm.startPrank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyChoice.selector);
        smartAccount.createTask("Test", REWARD_AMOUNT, DEADLINE_SECONDS, 3, address(0), DELAY_DURATION);
        vm.stopPrank();
    }

    function test_RevertCreateTask_BuddyPenaltyWithoutBuddy() public {
        vm.startPrank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        smartAccount.createTask("Test", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, address(0), 0);
        vm.stopPrank();
    }

    function test_RevertCreateTask_DelayedPenaltyWithoutDuration() public {
        vm.startPrank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        smartAccount.createTask("Test", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           TASK COMPLETION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_CompleteTask() public {
        vm.startPrank(owner);

        // Create task
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        uint256 initialBalance = owner.balance;
        uint256 initialCommitted = smartAccount.s_totalCommittedReward();

        vm.expectEmit(true, false, false, false);
        emit TaskCompleted(0);

        smartAccount.completeTask(0);

        TaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.COMPLETED));
        assertEq(owner.balance, initialBalance + REWARD_AMOUNT);
        assertEq(smartAccount.s_totalCommittedReward(), initialCommitted - REWARD_AMOUNT);

        vm.stopPrank();
    }

    function test_RevertCompleteTask_AlreadyCompleted() public {
        vm.startPrank(owner);

        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        smartAccount.completeTask(0);

        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCompleted.selector);
        smartAccount.completeTask(0);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           TASK CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_CancelTask() public {
        vm.startPrank(owner);

        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        uint256 initialCommitted = smartAccount.s_totalCommittedReward();

        vm.expectEmit(true, false, false, false);
        emit TaskCanceled(0);

        smartAccount.cancelTask(0);

        TaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(uint8(task.status), uint8(TaskManager.TaskStatus.CANCELED));
        assertEq(smartAccount.s_totalCommittedReward(), initialCommitted - REWARD_AMOUNT);

        vm.stopPrank();
    }

    function test_RevertCancelTask_AlreadyCanceled() public {
        vm.startPrank(owner);

        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        smartAccount.cancelTask(0);

        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCanceled.selector);
        smartAccount.cancelTask(0);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           TASK EXPIRATION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_ExpiredTaskCallback_DelayedPayment() public {
        vm.startPrank(owner);
        // Create task with delayed payment penalty
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.stopPrank();

        // Fast forward past deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Simulate TaskManager calling the callback
        vm.startPrank(address(smartAccount));
        vm.warp(block.timestamp + DEADLINE_SECONDS + 10);
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }
        vm.stopPrank();
    }

    function test_ExpiredTaskCallback_SendToBuddy() public {
        vm.startPrank(owner);

        // Create task with buddy penalty
        smartAccount.createTask("Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);
        vm.stopPrank();

        // Fund the SimpleAccount so it can pay the buddy
        vm.deal(address(smartAccount), REWARD_AMOUNT);

        uint256 buddyInitialBalance = buddy.balance;
        uint256 initialCommitted = smartAccount.s_totalCommittedReward();

        vm.startPrank(address(smartAccount));
        vm.warp(block.timestamp + DEADLINE_SECONDS + 10);
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }
        vm.stopPrank();

        // Simulate TaskManager calling the callback
        assertEq(buddy.balance, buddyInitialBalance + REWARD_AMOUNT);
        assertEq(smartAccount.s_totalCommittedReward(), initialCommitted - REWARD_AMOUNT);
    }

    function test_RevertExpiredTaskCallback_NotTaskManager() public {
        vm.startPrank(owner);
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.stopPrank();

        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        vm.prank(buddy);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyTaskManagerCanCall.selector);
        smartAccount.expiredTaskCallback(0);
    }

    /*//////////////////////////////////////////////////////////////
                      DELAYED PAYMENT RELEASE TESTS
    //////////////////////////////////////////////////////////////*/
    function test_ReleaseDelayedPayment() public {
        // Fund the SimpleAccount with enough ETH to pay the reward
        vm.deal(address(smartAccount), REWARD_AMOUNT);

        // Create the task as owner
        vm.startPrank(owner);
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.stopPrank();

        // Fast forward past the task deadline
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Expire the task through TaskManager (simulate upkeep)
        vm.startPrank(address(smartAccount));
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }
        vm.stopPrank();

        // Fast forward past the delay duration for delayed payment
        vm.warp(block.timestamp + DELAY_DURATION + 1);

        // Record owner's initial balance
        uint256 ownerInitialBalance = owner.balance;

        // Release the delayed payment as owner
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false);
        emit DelayedPaymentReleased(0, REWARD_AMOUNT);
        smartAccount.releaseDelayedPayment(0);
        vm.stopPrank();

        // Assert that owner received the reward
        assertEq(owner.balance, ownerInitialBalance + REWARD_AMOUNT);
        // Assert that the contract's balance decreased by the reward
        assertEq(address(smartAccount).balance, 0);
    }

    function test_RevertReleaseDelayedPayment_DurationNotElapsed() public {
        // Fund the SimpleAccount (optional, but good practice)
        vm.deal(address(smartAccount), REWARD_AMOUNT);

        // Create the task as owner
        vm.startPrank(owner);
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        vm.stopPrank();

        // Fast forward just past the deadline (but NOT past delay duration)
        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        // Expire the task via callback from TaskManager
        vm.startPrank(address(smartAccount));
        (bool upkeepNeeded, bytes memory performData) = taskManager.checkUpkeep("");
        if (upkeepNeeded) {
            taskManager.performUpkeep(performData);
        }
        vm.stopPrank();

        // Try to release delayed payment before delay duration has elapsed
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyDurationNotElapsed.selector);
        smartAccount.releaseDelayedPayment(0);
    }

    function test_RevertReleaseDelayedPayment_WrongPenaltyType() public {
        vm.startPrank(owner);

        smartAccount.createTask("Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyTypeMismatch.selector);
        smartAccount.releaseDelayedPayment(0);
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Transfer() public {
        address recipient = makeAddr("recipient");
        uint256 transferAmount = 1 ether;
        uint256 recipientInitialBalance = recipient.balance;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Transferred(recipient, transferAmount);

        smartAccount.transfer(recipient, transferAmount);

        assertEq(recipient.balance, recipientInitialBalance + transferAmount);
    }

    function test_RevertTransfer_OnlyOwner() public {
        vm.prank(buddy);
        vm.expectRevert(SmartAccount.SmartAccount__OnlyOwnerCanCall.selector);
        smartAccount.transfer(buddy, 1 ether);
    }

    function test_RevertTransfer_ZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__CannotTransferZero.selector);
        smartAccount.transfer(buddy, 0);
    }

    function test_RevertTransfer_CommittedRewards() public {
        vm.startPrank(owner);

        // Commit some rewards
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        uint256 availableBalance = address(smartAccount).balance - smartAccount.s_totalCommittedReward();

        vm.expectRevert(SmartAccount.SmartAccount__CannotWithdrawCommittedRewards.selector);
        smartAccount.transfer(buddy, availableBalance + 1);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           EXECUTE TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Execute() public {
        address target = makeAddr("target");
        uint256 value = 1 ether;
        bytes memory data = "";

        vm.deal(target, 0);

        vm.prank(entryPoint);
        smartAccount.execute(target, value, data);

        assertEq(target.balance, value);
    }

    function test_RevertExecute_NotFromEntryPoint() public {
        vm.prank(owner);
        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        smartAccount.execute(buddy, 1 ether, "");
    }

    /*//////////////////////////////////////////////////////////////
                         VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_ValidateUserOp() public {
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(smartAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 21000,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedMessageHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(entryPoint);
        uint256 validationData = smartAccount.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 0); // SIG_VALIDATION_SUCCESS
    }

    // function test_ValidateUserOp_InvalidSignature() public {
    //     // 65 bytes: 64 bytes of nonzero, last byte is 27
    //     bytes memory fakeSignature =
    //         hex"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f601b";

    //     PackedUserOperation memory userOp = PackedUserOperation({
    //         sender: address(smartAccount),
    //         nonce: 0,
    //         initCode: "",
    //         callData: "",
    //         accountGasLimits: bytes32(0),
    //         preVerificationGas: 21000,
    //         gasFees: bytes32(0),
    //         paymasterAndData: "",
    //         signature: fakeSignature
    //     });

    //     bytes32 userOpHash = keccak256(abi.encode(userOp));

    //     vm.prank(entryPoint);
    //     uint256 validationData = smartAccount.validateUserOp(userOp, userOpHash, 0);

    //     assertEq(validationData, 1); // SIG_VALIDATION_FAILED
    // }

    /*//////////////////////////////////////////////////////////////
                           GETTER TESTS
    //////////////////////////////////////////////////////////////*/
    function test_GetTaskManagerAddress() public view {
        assertEq(smartAccount.getTaskManagerAddress(), address(taskManager));
    }

    function test_GetTask() public {
        vm.startPrank(owner);
        smartAccount.createTask(
            "Test task", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );

        TaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(task.description, "Test task");
        assertEq(task.rewardAmount, REWARD_AMOUNT);
        vm.stopPrank();
    }

    function test_GetTotalTasks() public {
        assertEq(smartAccount.getTotalTasks(), 0);

        vm.startPrank(owner);
        smartAccount.createTask(
            "Task 1", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        assertEq(smartAccount.getTotalTasks(), 1);

        smartAccount.createTask(
            "Task 2", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        assertEq(smartAccount.getTotalTasks(), 2);
        vm.stopPrank();
    }

    function test_GetAllTasks() public {
        vm.startPrank(owner);
        smartAccount.createTask(
            "Task 1", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_DELAYEDPAYMENT, address(0), DELAY_DURATION
        );
        smartAccount.createTask("Task 2", REWARD_AMOUNT, DEADLINE_SECONDS, PENALTY_SENDBUDDY, buddy, 0);

        TaskManager.Task[] memory tasks = smartAccount.getAllTasks();
        assertEq(tasks.length, 2);
        assertEq(tasks[0].description, "Task 1");
        assertEq(tasks[1].description, "Task 2");
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           FALLBACK TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Fallback() public {
        uint256 initialBalance = address(smartAccount).balance;
        uint256 sendAmount = 1 ether;

        (bool success,) = payable(address(smartAccount)).call{value: sendAmount}("nonexistent");
        assertTrue(success);
        assertEq(address(smartAccount).balance, initialBalance + sendAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function createTaskAndExpire(uint8 penaltyType, address penaltyBuddy, uint256 delayDuration)
        internal
        returns (uint256 taskId)
    {
        vm.startPrank(owner);
        smartAccount.createTask("Test task", REWARD_AMOUNT, DEADLINE_SECONDS, penaltyType, penaltyBuddy, delayDuration);
        vm.stopPrank();

        vm.warp(block.timestamp + DEADLINE_SECONDS + 1);

        return 0; // First task ID
    }
}
