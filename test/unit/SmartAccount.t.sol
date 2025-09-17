// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {SmartAccount} from "../../src/SmartAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ITaskManager} from "../../src/interface/ITaskManager.sol";
import {ISmartAccount} from "../../src/interface/ISmartAccount.sol";
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {UserOperation} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title SmartAccountTest
 * @author Test Suite
 * @notice Comprehensive test suite for SmartAccount contract
 * @dev Tests all functionality including initialization, task management, penalties, and signature verification
 */
contract SmartAccountTest is Test {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    SmartAccount public smartAccount;
    MockEntryPoint public mockEntryPoint;
    MockTaskManager public mockTaskManager;

    address public alice;
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public buddy = makeAddr("buddy");

    uint256 public alicePrivateKey;

    uint256 public constant INITIAL_BALANCE = 10 ether;
    uint256 public constant TASK_REWARD = 1 ether;
    uint256 public constant DEADLINE_DURATION = 7 days;
    uint256 public constant DELAY_DURATION = 1 days;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Initialized(address indexed owner, address indexed entryPoint, address indexed taskManager);
    event TaskCreated(uint256 indexed taskId, string indexed description, uint256 indexed rewardAmount);
    event TaskCompleted(uint256 indexed taskId, uint256 indexed rewardAmount);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event DurationPenaltyApplied(uint256 indexed taskId, uint256 indexed penaltyDuration);
    event DelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);
    event PenaltyFundsReleasedToBuddy(uint256 indexed taskId, uint256 indexed rewardAmount, address indexed buddy);
    event BuddyPaymentFailed(uint256 indexed taskId, address indexed buddy, string reason);
    event DepositAdded(address indexed sender, uint256 indexed amount);
    event DepositWithdrawn(address indexed withdrawAddress, uint256 indexed amount);
    event FundsUnlocked(uint256 indexed taskId, uint256 indexed amount, string indexed reason);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Generate Alice's private key and address
        alicePrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        alice = vm.addr(alicePrivateKey);

        // Deploy mock contracts
        mockEntryPoint = new MockEntryPoint();
        mockTaskManager = new MockTaskManager();

        // Deploy SmartAccount implementation
        SmartAccount implementation = new SmartAccount();

        // Create a clone using OpenZeppelin Clones
        address clone = Clones.clone(address(implementation));
        smartAccount = SmartAccount(payable(clone));

        // Initialize the clone
        smartAccount.initialize(alice, address(mockEntryPoint), ITaskManager(address(mockTaskManager)));

        // Fund the account
        vm.deal(address(smartAccount), INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_Success() public {
        // Test that our setUp properly initialized the account
        assertEq(smartAccount.s_owner(), alice);
        assertEq(address(smartAccount.i_entryPoint()), address(mockEntryPoint));
        assertEq(address(smartAccount.taskManager()), address(mockTaskManager));
        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            TASK CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateTask_Success() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        vm.expectEmit(true, true, true, true);
        emit TaskCreated(0, "Test task", TASK_REWARD);

        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0 // Manual verification
        );

        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE - TASK_REWARD);
    }

    function test_CreateTask_BuddyPenalty() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            buddy,
            0 // Manual verification
        );

        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
    }

    function test_CreateTask_InvalidPenaltyChoice() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__PickAPenalty.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            0, // Invalid choice
            DELAY_DURATION,
            address(0),
            0
        );
    }

    function test_CreateTask_InvalidPenaltyChoiceTooHigh() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyChoice.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            3, // Invalid choice
            DELAY_DURATION,
            address(0),
            0
        );
    }

    function test_CreateTask_InvalidBuddyConfig() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            address(0), // Invalid buddy
            0
        );
    }

    function test_CreateTask_InvalidDelayConfig() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            0, // Invalid delay duration
            address(0),
            0
        );
    }

    function test_CreateTask_ZeroReward() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__RewardCannotBeZero.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            0, // Zero reward
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
    }

    function test_CreateTask_DeadlineTooLarge() public {
        uint256 deadline = block.timestamp + (365 days * 101); // Too large

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__DeadlineToLarge.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
    }

    function test_CreateTask_InsufficientFunds() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;
        uint256 largeReward = INITIAL_BALANCE + 1 ether;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__AddMoreFunds.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            largeReward,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
    }

    function test_CreateTask_NotFromEntryPoint() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                            TASK COMPLETION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CompleteTask_Success() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Complete task
        vm.prank(address(mockEntryPoint));
        vm.expectEmit(true, true, true, true);
        emit TaskCompleted(0, TASK_REWARD);

        smartAccount.completeTask(0);

        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE);
    }

    function test_CompleteTask_AlreadyCompleted() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create and complete task
        vm.startPrank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
        smartAccount.completeTask(0);

        // Try to complete again
        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCompleted.selector);
        smartAccount.completeTask(0);
        vm.stopPrank();
    }

    function test_CompleteTask_AlreadyCanceled() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create and cancel task
        vm.startPrank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
        smartAccount.cancelTask(0);

        // Try to complete canceled task
        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCanceled.selector);
        smartAccount.completeTask(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            TASK CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CancelTask_Success() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Cancel task
        vm.prank(address(mockEntryPoint));
        vm.expectEmit(true, true, true, true);
        emit TaskCanceled(0);

        smartAccount.cancelTask(0);

        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE);
    }

    function test_CancelTask_AlreadyCanceled() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create and cancel task
        vm.startPrank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
        smartAccount.cancelTask(0);

        // Try to cancel again
        vm.expectRevert(SmartAccount.SmartAccount__TaskAlreadyCanceled.selector);
        smartAccount.cancelTask(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            PENALTY MECHANISM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExpiredTaskCallback_DelayedPayment() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with delayed payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Simulate task expiration
        vm.warp(deadline + 1);

        vm.prank(address(mockTaskManager));
        vm.expectEmit(true, true, true, true);
        emit DurationPenaltyApplied(0, deadline + DELAY_DURATION);

        smartAccount.expiredTaskCallback(0);

        // Funds should still be committed
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
    }

    function test_ExpiredTaskCallback_BuddyPayment() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with buddy payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            buddy,
            0
        );

        // Simulate task expiration
        vm.warp(deadline + 1);

        vm.prank(address(mockTaskManager));
        vm.expectEmit(true, true, true, true);
        emit PenaltyFundsReleasedToBuddy(0, TASK_REWARD, buddy);

        smartAccount.expiredTaskCallback(0);

        // Funds should be released
        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(buddy.balance, TASK_REWARD);
    }

    function test_ExpiredTaskCallback_BuddyPaymentFailed() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Deploy a contract that rejects ETH
        RejectingContract rejectingContract = new RejectingContract();

        // Create task with buddy payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            address(rejectingContract), // Contract that will reject ETH
            0
        );

        // Simulate task expiration
        vm.warp(deadline + 1);

        vm.prank(address(mockTaskManager));
        smartAccount.expiredTaskCallback(0);

        // Funds should remain committed for manual retry
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
    }

    function test_ReleaseDelayedPayment_Success() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with delayed payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Simulate task expiration and delay period elapsed
        vm.warp(deadline + DELAY_DURATION + 1);

        vm.prank(address(mockEntryPoint));
        vm.expectEmit(true, true, true, true);
        emit DelayedPaymentReleased(0, TASK_REWARD);

        smartAccount.releaseDelayedPayment(0);

        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    function test_ReleaseDelayedPayment_PenaltyDurationNotElapsed() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with delayed payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Simulate task expiration but delay period not elapsed
        vm.warp(deadline + DELAY_DURATION - 1);

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyDurationNotElapsed.selector);
        smartAccount.releaseDelayedPayment(0);
    }

    function test_ReleaseBuddyPayment_Success() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with buddy payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            buddy,
            0
        );

        // Simulate task expiration
        vm.warp(deadline + 1);

        vm.prank(address(mockEntryPoint));
        smartAccount.releaseBuddyPayment(0);

        // The function should succeed (no revert), but funds are not immediately transferred
        // The actual transfer happens through automatedBuddyPaymentAttempt
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddDeposit_Success() public {
        uint256 depositAmount = 1 ether;

        // Give Alice some ETH first
        vm.deal(alice, depositAmount);

        vm.prank(alice);
        smartAccount.addDeposit{value: depositAmount}();

        assertEq(mockEntryPoint.deposits(address(smartAccount)), depositAmount);
    }

    function test_WithdrawDepositTo_Success() public {
        uint256 depositAmount = 1 ether;

        // Give Alice some ETH first
        vm.deal(alice, depositAmount);

        // Add deposit first
        vm.prank(alice);
        smartAccount.addDeposit{value: depositAmount}();

        // Withdraw deposit
        vm.prank(address(mockEntryPoint));
        smartAccount.withdrawDepositTo(payable(bob), depositAmount);

        assertEq(bob.balance, depositAmount);
    }

    function test_WithdrawDepositTo_NotFromEntryPoint() public {
        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        smartAccount.withdrawDepositTo(payable(bob), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Execute_Success() public {
        uint256 transferAmount = 1 ether;

        vm.prank(address(mockEntryPoint));
        smartAccount.execute(bob, transferAmount, "");

        assertEq(bob.balance, transferAmount);
        assertEq(address(smartAccount).balance, INITIAL_BALANCE - transferAmount);
    }

    function test_Execute_NotFromEntryPoint() public {
        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        smartAccount.execute(bob, 1 ether, "");
    }

    function test_Execute_InsufficientFunds() public {
        uint256 largeAmount = INITIAL_BALANCE + 1 ether;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__CannotWithdrawCommittedRewards.selector);
        smartAccount.execute(bob, largeAmount, "");
    }

    function test_Execute_CannotWithdrawCommittedRewards() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task to commit funds
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Try to withdraw more than available balance
        uint256 withdrawAmount = INITIAL_BALANCE - TASK_REWARD + 1;

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(SmartAccount.SmartAccount__CannotWithdrawCommittedRewards.selector);
        smartAccount.execute(bob, withdrawAmount, "");
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-1271 SIGNATURE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_IsValidSignature_EIP191() public view {
        bytes32 messageHash = keccak256("Hello World");
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        // Sign with Alice's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = smartAccount.isValidSignature(messageHash, signature);
        assertEq(uint32(result), uint32(0x1626ba7e));
    }

    function test_IsValidSignature_EIP712() public view {
        bytes32 messageHash = keccak256("Hello World");

        // Sign with Alice's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = smartAccount.isValidSignature(messageHash, signature);
        assertEq(uint32(result), uint32(0x1626ba7e));
    }

    function test_IsValidSignature_InvalidSignature() public {
        bytes32 messageHash = keccak256("Hello World");

        // Sign with Bob's private key (not the owner)
        uint256 bobPrivateKey = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = smartAccount.isValidSignature(messageHash, signature);
        assertEq(result, bytes4(0));
    }

    /*//////////////////////////////////////////////////////////////
                            USER OPERATION VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ValidateUserOp_ValidSignature() public {
        UserOperation memory userOp = UserOperation({
            sender: address(smartAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 100000,
            verificationGasLimit: 100000,
            preVerificationGas: 100000,
            maxFeePerGas: 1000000000,
            maxPriorityFeePerGas: 1000000000,
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Create EIP-712 digest like SmartAccount does
        bytes32 TYPE_HASH = keccak256("UserOperation(bytes32 userOpHash)");
        bytes32 structHash = keccak256(abi.encode(TYPE_HASH, userOpHash));

        bytes32 DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes("EntryPoint"));
        bytes32 versionHash = keccak256(bytes("0.6"));
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, nameHash, versionHash, block.chainid, address(mockEntryPoint)));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with Alice's private key against the EIP-712 digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(address(mockEntryPoint));
        uint256 validationData = smartAccount.validateUserOp(userOp, userOpHash, 0);

        // Should return success (validationData = 0)
        assertEq(validationData, 0);
    }

    function test_ValidateUserOp_InvalidSignature() public {
        UserOperation memory userOp = UserOperation({
            sender: address(smartAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 100000,
            verificationGasLimit: 100000,
            preVerificationGas: 100000,
            maxFeePerGas: 1000000000,
            maxPriorityFeePerGas: 1000000000,
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Sign with Bob's private key (not the owner)
        uint256 bobPrivateKey = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(address(mockEntryPoint));
        uint256 validationData = smartAccount.validateUserOp(userOp, userOpHash, 0);

        // Should return failure (validationData != 0)
        assertTrue(validationData != 0);
    }

    function test_ValidateUserOp_NotFromEntryPoint() public {
        UserOperation memory userOp = UserOperation({
            sender: address(smartAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 100000,
            verificationGasLimit: 100000,
            preVerificationGas: 100000,
            maxFeePerGas: 1000000000,
            maxPriorityFeePerGas: 1000000000,
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));

        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        smartAccount.validateUserOp(userOp, userOpHash, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetAvailableBalance() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task to commit funds
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        uint256 availableBalance = smartAccount.getAvailableBalance();
        assertEq(availableBalance, INITIAL_BALANCE - TASK_REWARD);
    }

    function test_GetTask() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        ITaskManager.Task memory task = smartAccount.getTask(0);
        assertEq(task.id, 0);
        assertEq(task.rewardAmount, TASK_REWARD);
    }

    function test_GetTotalTasks() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create multiple tasks
        vm.startPrank(address(mockEntryPoint));
        smartAccount.createTask(
            "Task 1",
            "Task 1",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
        smartAccount.createTask(
            "Task 2",
            "Task 2",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
        vm.stopPrank();

        uint256 totalTasks = smartAccount.getTotalTasks();
        assertEq(totalTasks, 2);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERFACE SUPPORT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SupportsInterface() public {
        assertTrue(smartAccount.supportsInterface(type(ISmartAccount).interfaceId));
        assertTrue(smartAccount.supportsInterface(type(IAccount).interfaceId));
        assertTrue(smartAccount.supportsInterface(type(IERC165).interfaceId));
        assertFalse(smartAccount.supportsInterface(0x12345678));
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveEther() public {
        uint256 sendAmount = 1 ether;

        // Give Alice some ETH first
        vm.deal(alice, sendAmount);

        vm.prank(alice);
        (bool success,) = address(smartAccount).call{value: sendAmount}("");
        assertTrue(success);

        assertEq(address(smartAccount).balance, INITIAL_BALANCE + sendAmount);
    }

    function test_Fallback() public {
        uint256 sendAmount = 1 ether;

        // Give Alice some ETH first
        vm.deal(alice, sendAmount);

        vm.prank(alice);
        (bool success,) = address(smartAccount).call{value: sendAmount}("");
        assertTrue(success);

        assertEq(address(smartAccount).balance, INITIAL_BALANCE + sendAmount);
    }

    function test_AutomatedDelayedPaymentRelease() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with delayed payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Simulate task expiration and delay period elapsed
        vm.warp(deadline + DELAY_DURATION + 1);

        vm.prank(address(mockTaskManager));
        vm.expectEmit(true, true, true, true);
        emit DelayedPaymentReleased(0, TASK_REWARD);

        smartAccount.automatedDelayedPaymentRelease(0);

        assertEq(smartAccount.s_totalCommittedReward(), 0);
    }

    function test_AutomatedBuddyPaymentAttempt_Success() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task with buddy payment penalty
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            buddy,
            0
        );

        // Simulate task expiration
        vm.warp(deadline + 1);

        vm.prank(address(mockTaskManager));
        bool success = smartAccount.automatedBuddyPaymentAttempt(0);

        assertTrue(success);
        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(buddy.balance, TASK_REWARD);
    }

    function test_AutomatedBuddyPaymentAttempt_Failed() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Deploy a contract that rejects ETH
        RejectingContract rejectingContract = new RejectingContract();

        // Create task with buddy payment penalty to a contract that rejects ETH
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Test Task",
            "Test task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            address(rejectingContract), // Contract that will reject ETH
            0
        );

        // Simulate task expiration
        vm.warp(deadline + 1);

        vm.prank(address(mockTaskManager));
        bool success = smartAccount.automatedBuddyPaymentAttempt(0);

        assertFalse(success);
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
    }

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CompleteTaskLifecycle() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create task
        vm.prank(address(mockEntryPoint));
        smartAccount.createTask(
            "Integration Task",
            "Complete lifecycle test",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );

        // Verify task creation
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE - TASK_REWARD);

        // Complete task
        vm.prank(address(mockEntryPoint));
        smartAccount.completeTask(0);

        // Verify task completion
        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE);
    }

    function test_Integration_MultipleTasks() public {
        uint256 deadline = block.timestamp + DEADLINE_DURATION;

        // Create multiple tasks
        vm.startPrank(address(mockEntryPoint));
        smartAccount.createTask(
            "Task 1",
            "First task",
            TASK_REWARD,
            deadline,
            1, // PENALTY_DELAYEDPAYMENT
            DELAY_DURATION,
            address(0),
            0
        );
        smartAccount.createTask(
            "Task 2",
            "Second task",
            TASK_REWARD,
            deadline,
            2, // PENALTY_SENDBUDDY
            0,
            buddy,
            0
        );
        vm.stopPrank();

        // Verify both tasks are committed
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD * 2);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE - (TASK_REWARD * 2));

        // Complete first task
        vm.prank(address(mockEntryPoint));
        smartAccount.completeTask(0);

        // Verify partial completion
        assertEq(smartAccount.s_totalCommittedReward(), TASK_REWARD);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE - TASK_REWARD);

        // Cancel second task
        vm.prank(address(mockEntryPoint));
        smartAccount.cancelTask(1);

        // Verify all funds are available
        assertEq(smartAccount.s_totalCommittedReward(), 0);
        assertEq(smartAccount.getAvailableBalance(), INITIAL_BALANCE);
    }
}

/*//////////////////////////////////////////////////////////////
                            MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/**
 * @title MockEntryPoint
 * @notice Mock implementation of EntryPoint for testing
 */
contract MockEntryPoint {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {
        require(deposits[msg.sender] >= withdrawAmount, "Insufficient deposit");
        deposits[msg.sender] -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
    }
}

/**
 * @title MockTaskManager
 * @notice Mock implementation of TaskManager for testing
 */
contract MockTaskManager is ITaskManager {
    mapping(address => mapping(uint256 => Task)) public tasks;
    mapping(address => uint256) public taskCounts;

    function createTask(
        string calldata title,
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external override returns (uint256) {
        uint256 taskId = taskCounts[msg.sender]++;

        tasks[msg.sender][taskId] = Task({
            id: taskId,
            title: title,
            description: description,
            rewardAmount: rewardAmount,
            deadline: deadlineInSeconds,
            valid: true,
            status: TaskStatus.ACTIVE,
            choice: choice,
            delayDuration: delayDuration,
            buddy: buddy,
            delayedRewardReleased: false,
            buddyPaymentSent: false,
            verificationMethod: VerificationMethod(verificationMethod)
        });

        return taskId;
    }

    function completeTask(uint256 taskId) external override {
        tasks[msg.sender][taskId].status = TaskStatus.COMPLETED;
    }

    function cancelTask(uint256 taskId) external override {
        tasks[msg.sender][taskId].status = TaskStatus.CANCELED;
    }

    function releaseDelayedPayment(uint256 taskId) external override {
        tasks[msg.sender][taskId].delayedRewardReleased = true;
    }

    function releaseBuddyPayment(uint256 taskId) external override {
        tasks[msg.sender][taskId].buddyPaymentSent = true;
    }

    function getTask(address account, uint256 taskId) external view override returns (Task memory) {
        Task memory task = tasks[account][taskId];

        // Simulate task expiration if deadline has passed
        if (task.deadline > 0 && block.timestamp > task.deadline && task.status == TaskStatus.ACTIVE) {
            task.status = TaskStatus.EXPIRED;
        }

        return task;
    }

    function getTasksByStatus(address, TaskStatus, uint256, uint256) external pure override returns (Task[] memory) {
        Task[] memory result = new Task[](0);
        return result;
    }

    function getTaskCountsByStatus(address) external pure override returns (uint256[] memory) {
        uint256[] memory result = new uint256[](4);
        return result;
    }

    function getTotalTasks(address account) external view override returns (uint256) {
        return taskCounts[account];
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITaskManager).interfaceId;
    }
}

/**
 * @title RejectingContract
 * @notice Contract that rejects ETH transfers
 */
contract RejectingContract {
    receive() external payable {
        revert("ETH not accepted");
    }

    fallback() external payable {
        revert("ETH not accepted");
    }
}
