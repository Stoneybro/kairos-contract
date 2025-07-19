// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {SimpleAccount} from "src/SimpleAccount.sol";
import {TaskManager} from "src/TaskManager.sol";
import {MockTaskManager} from "test/Mocks/MockTaskManager.t.sol";
import {PackedUserOperation} from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "lib/account-abstraction/contracts/core/Helpers.sol";

contract MockEntryPoint {
    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }
    receive() external payable {}
}

contract SimpleAccountTest is Test {
    SimpleAccount account;
    TaskManager taskManager;
    MockTaskManager mockTaskManager;
    MockEntryPoint entryPoint;

    uint256 ownerPrivateKey = 1;
    address owner = vm.addr(ownerPrivateKey);
    address attacker = makeAddr("attacker");
    address buddy = makeAddr("buddy");
    address nonOwner = makeAddr("nonOwner");

    event TaskManagerLinked(address indexed taskManager);
    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event DurationPenaltyApplied(uint256 indexed taskId, uint256 indexed penaltyDuration);
    event DelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);
    event PenaltyFundsReleasedToBuddy(uint256 indexed taskId, uint256 indexed rewardAmount, address indexed buddy);

    function setUp() public {
        account = new SimpleAccount();
        entryPoint = new MockEntryPoint();
        account.initialize(owner, address(entryPoint));
        vm.deal(address(account), 10 ether);

        taskManager = new TaskManager(address(account));
        mockTaskManager = new MockTaskManager();
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitialize() public {
        SimpleAccount newAccount = new SimpleAccount();
        newAccount.initialize(owner, address(entryPoint));

        assertEq(newAccount.s_owner(), owner);
    }

    function testInitializeOnlyOnce() public {
        vm.expectRevert();
        account.initialize(owner, address(entryPoint));
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIER TESTS
    //////////////////////////////////////////////////////////////*/

    function testOnlyOwnerModifier() public {
        vm.prank(attacker);
        vm.expectRevert(SimpleAccount.SimpleAccount__OnlyOwnerCanCall.selector);
        account.deployAndLinkTaskManager();
    }

    function testRequireFromEntryPointModifier() public {
        vm.prank(attacker);
        vm.expectRevert(SimpleAccount.SimpleAccount__NotFromEntryPoint.selector);
        account.execute(address(0), 0, "");
    }

    /*//////////////////////////////////////////////////////////////
                         TASK MANAGER DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function testDeployAndLinkTaskManager() public {
        vm.prank(owner);
        vm.expectEmit(false, true, false, false);
        emit TaskManagerLinked(address(0)); // We don't know the address beforehand
        account.deployAndLinkTaskManager();

        assertTrue(address(account.taskManager()) != address(0));
    }

    function testDeployAndLinkTaskManagerAlreadyDeployed() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();

        vm.expectRevert(SimpleAccount.SimpleAccount__TaskManagerAlreadyDeployed.selector);
        account.deployAndLinkTaskManager();
        vm.stopPrank();
    }

    function testGetTaskManagerAddress() public {
        vm.prank(owner);
        account.deployAndLinkTaskManager();

        address retrievedManager = account.getTaskManagerAddress();
        assertEq(retrievedManager, address(account.taskManager()));
    }

    /*//////////////////////////////////////////////////////////////
                           PENALTY MECHANISM TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetDelayPenalty() public {
        uint256 delayDuration = 1 days;

        vm.prank(owner);
        account.setDelayPenalty(delayDuration);

        assertEq(account.getPenaltyChoice(), 1);
        assertEq(account.getDelayDuration(), delayDuration);
    }

    function testSetBuddyPenalty() public {
        vm.prank(owner);
        account.setBuddyPenalty(buddy);

        assertEq(account.getPenaltyChoice(), 2);
        assertEq(account.getBuddy(), buddy);
    }

    function testSetBuddyPenaltyZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__PickAPenalty.selector);
        account.setBuddyPenalty(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              TASK CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCreateTaskSuccess() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);

        vm.expectEmit(true, false, false, true);
        emit TaskCreated(0, "Test Task", 1 ether);
        account.createTask("Test Task", 1 ether, 1 days);

        assertEq(account.s_totalCommittedReward(), 1 ether);
        vm.stopPrank();
    }

    function testCreateTaskNoTaskManagerLinked() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__NoTaskManagerLinked.selector);
        account.createTask("Test", 1 ether, 1 days);
    }

    function testCreateTaskNoPenaltyChosen() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();

        vm.expectRevert(SimpleAccount.SimpleAccount__PickAPenalty.selector);
        account.createTask("Test", 1 ether, 1 days);
        vm.stopPrank();
    }

    function testCreateTaskInsufficientFunds() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);

        // Drain the account
        vm.deal(address(account), 0);

        vm.expectRevert(SimpleAccount.SimpleAccount__AddMoreFunds.selector);
        account.createTask("Test", 1 ether, 1 days);
        vm.stopPrank();
    }

    function testCreateTaskFailure() public {
        // Use mock task manager that can be set to fail
        vm.startPrank(owner);
        // Note: This test requires a mock that can simulate task creation failure
        // The actual implementation would need to be adjusted based on your MockTaskManager
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           TASK COMPLETION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteTaskSuccess() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);
        account.createTask("Test", 1 ether, 1 days);

        uint256 initialBalance = owner.balance;

        vm.expectEmit(true, false, false, false);
        emit TaskCompleted(0);
        account.completeTask(0);

        assertEq(account.s_totalCommittedReward(), 0);
        assertEq(owner.balance, initialBalance + 1 ether);
        vm.stopPrank();
    }

    function testCompleteTaskNoTaskManager() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__NoTaskManagerLinked.selector);
        account.completeTask(0);
    }

    function testCompleteTaskPaymentFailure() public {
        // Create a contract that cannot receive ether to test payment failure
        RevertOnReceive revertContract = new RevertOnReceive();

        vm.startPrank(address(revertContract));
        SimpleAccount revertAccount = new SimpleAccount();
        revertAccount.initialize(address(revertContract), address(entryPoint));
        vm.deal(address(revertAccount), 10 ether);

        revertAccount.deployAndLinkTaskManager();
        revertAccount.setDelayPenalty(1 days);
        revertAccount.createTask("Test", 1 ether, 1 days);

        vm.expectRevert(SimpleAccount.SimpleAccount__TaskRewardPaymentFailed.selector);
        revertAccount.completeTask(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           TASK CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCancelTaskSuccess() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);
        account.createTask("Test", 1 ether, 1 days);

        vm.expectEmit(true, false, false, false);
        emit TaskCanceled(0);
        account.cancelTask(0);

        assertEq(account.s_totalCommittedReward(), 0);
        vm.stopPrank();
    }

    function testCancelTaskNoTaskManager() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__NoTaskManagerLinked.selector);
        account.cancelTask(0);
    }

    /*//////////////////////////////////////////////////////////////
                        EXPIRED TASK CALLBACK TESTS
    //////////////////////////////////////////////////////////////*/

    function testExpiredTaskCallbackDelayPenalty() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);
        account.createTask("Test", 1 ether, 0); // Expires immediately
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.prank(address(account.taskManager()));
        vm.expectEmit(true, true, false, false);
        emit DurationPenaltyApplied(0, block.timestamp + 1 days - 1);
        account.expiredTaskCallback(0);
    }

    function testExpiredTaskCallbackBuddyPenalty() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setBuddyPenalty(buddy);
        account.createTask("Test", 1 ether, 0); // Expires immediately
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 initialBuddyBalance = buddy.balance;

        vm.prank(address(account.taskManager()));
        vm.expectEmit(true, true, true, false);
        emit PenaltyFundsReleasedToBuddy(0, 1 ether, buddy);
        account.expiredTaskCallback(0);

        assertEq(buddy.balance, initialBuddyBalance + 1 ether);
        assertEq(account.s_totalCommittedReward(), 0);
    }

    function testExpiredTaskCallbackUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(SimpleAccount.SimpleAccount__OnlyTaskManagerCanCall.selector);
        account.expiredTaskCallback(0);
    }

    function testExpiredTaskCallbackBuddyPaymentFailure() public {
        RevertOnReceive revertBuddy = new RevertOnReceive();

        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setBuddyPenalty(address(revertBuddy));
        account.createTask("Test", 1 ether, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.prank(address(account.taskManager()));
        vm.expectRevert(SimpleAccount.SimpleAccount__TaskRewardPaymentFailed.selector);
        account.expiredTaskCallback(0);
    }

    /*//////////////////////////////////////////////////////////////
                       DELAYED PAYMENT RELEASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testReleaseDelayedPaymentSuccess() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);
        account.createTask("Test", 1 ether, 0);
        vm.stopPrank();

        // Expire the task
        vm.warp(block.timestamp + 1);
        vm.prank(address(account.taskManager()));
        account.expiredTaskCallback(0);

        // Wait for delay duration
        vm.warp(block.timestamp + 1 days);

        uint256 initialBalance = owner.balance;

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit DelayedPaymentReleased(0, 1 ether);
        account.releaseDelayedPayment(0);

        assertEq(owner.balance, initialBalance + 1 ether);
        assertEq(account.s_totalCommittedReward(), 0);
    }

    function testReleaseDelayedPaymentWrongPenaltyType() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setBuddyPenalty(buddy);
        account.createTask("Test", 1 ether, 0);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__PenaltyTypeMismatch.selector);
        account.releaseDelayedPayment(0);
    }

    function testReleaseDelayedPaymentDurationNotElapsed() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);
        account.createTask("Test", 1 ether, 0);
        vm.stopPrank();

        // Expire the task
        vm.warp(block.timestamp + 1);
        vm.prank(address(account.taskManager()));
        account.expiredTaskCallback(0);

        // Don't wait for delay duration
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__PenaltyDurationNotElapsed.selector);
        account.releaseDelayedPayment(0);
    }

    function testReleaseDelayedPaymentFailure() public {
        RevertOnReceive revertContract = new RevertOnReceive();

        vm.startPrank(address(revertContract));
        SimpleAccount revertAccount = new SimpleAccount();
        revertAccount.initialize(address(revertContract), address(entryPoint));
        vm.deal(address(revertAccount), 10 ether);

        revertAccount.deployAndLinkTaskManager();
        revertAccount.setDelayPenalty(1 days);
        revertAccount.createTask("Test", 1 ether, 0);
        vm.stopPrank();

        // Expire the task
        vm.warp(block.timestamp + 1);
        vm.prank(address(revertAccount.taskManager()));
        revertAccount.expiredTaskCallback(0);

        // Wait for delay duration
        vm.warp(block.timestamp + 1 days);

        vm.prank(address(revertContract));
        vm.expectRevert(SimpleAccount.SimpleAccount__TaskRewardPaymentFailed.selector);
        revertAccount.releaseDelayedPayment(0);
    }

    /*//////////////////////////////////////////////////////////////
                        TASK REWARDS CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetSumOfActiveTasksRewards() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);

        account.createTask("Task 1", 1 ether, 1 days);
        account.createTask("Task 2", 2 ether, 1 days);
        account.createTask("Task 3", 3 ether, 1 days);

        assertEq(account.getSumOfActiveTasksRewards(), 6 ether);

        // Complete one task
        account.completeTask(0);
        assertEq(account.getSumOfActiveTasksRewards(), 5 ether);

        // Cancel one task
        account.cancelTask(1);
        assertEq(account.getSumOfActiveTasksRewards(), 3 ether);
        vm.stopPrank();
    }

    function testGetSumOfActiveTasksRewardsNoTaskManager() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__NoTaskManagerLinked.selector);
        account.getSumOfActiveTasksRewards();
    }

    /*//////////////////////////////////////////////////////////////
                           TASK GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetTask() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);
        account.createTask("Test Task", 1 ether, 1 days);

        TaskManager.Task memory task = account.getTask(0);
        assertEq(task.description, "Test Task");
        assertEq(task.rewardAmount, 1 ether);
        vm.stopPrank();
    }

    function testGetTaskNoTaskManager() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__NoTaskManagerLinked.selector);
        account.getTask(0);
    }

    function testGetTotalTask() public {
        vm.startPrank(owner);
        account.deployAndLinkTaskManager();
        account.setDelayPenalty(1 days);

        assertEq(account.getTotalTask(), 0);

        account.createTask("Task 1", 1 ether, 1 days);
        assertEq(account.getTotalTask(), 1);

        account.createTask("Task 2", 1 ether, 1 days);
        assertEq(account.getTotalTask(), 2);
        vm.stopPrank();
    }

    function testGetTotalTaskNoTaskManager() public {
        vm.prank(owner);
        vm.expectRevert(SimpleAccount.SimpleAccount__NoTaskManagerLinked.selector);
        account.getTotalTask();
    }

    /*//////////////////////////////////////////////////////////////
                           ENTRY POINT TESTS
    //////////////////////////////////////////////////////////////*/

    function testExecuteSuccess() public {
        address target = makeAddr("target");
        vm.deal(target, 0);

        vm.prank(address(entryPoint));
        account.execute(target, 1 ether, "");

        assertEq(target.balance, 1 ether);
    }

    function testExecuteFailure() public {
        RevertOnReceive revertContract = new RevertOnReceive();

        vm.prank(address(entryPoint));
        vm.expectRevert();
        account.execute(address(revertContract), 1 ether, "");
    }

    function testValidateUserOpSuccess() public {
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256("test");
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedMessageHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, SIG_VALIDATION_SUCCESS);
    }

    function testValidateUserOpInvalidSignature() public {
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: abi.encodePacked(bytes32(0), bytes32(0), uint8(0))
        });

        bytes32 userOpHash = keccak256("test");

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(validationData, SIG_VALIDATION_FAILED);
    }

    function testValidateUserOpWithPrefund() public {
        bytes memory callData = abi.encodeWithSelector(account.execute.selector, address(this), 0, "");
        
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256(abi.encode(userOp));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedMessageHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.deal(address(account), 2 ether);
        
        uint256 entryPointBalanceBefore = address(entryPoint).balance;
        uint256 prefundAmount = 1 ether;

        vm.prank(address(entryPoint));
        uint256 validationResult = account.validateUserOp(userOp, userOpHash, prefundAmount);

        assertEq(validationResult, SIG_VALIDATION_SUCCESS);
        
        uint256 entryPointBalanceAfter = address(entryPoint).balance;
        assertEq(entryPointBalanceAfter - entryPointBalanceBefore, prefundAmount);
        assertEq(address(account).balance, 2 ether - prefundAmount);
    }

    function testPayPrefundFailure() public {
        RevertOnReceive revertEntryPoint = new RevertOnReceive();

        SimpleAccount revertAccount = new SimpleAccount();
        revertAccount.initialize(owner, address(revertEntryPoint));
        vm.deal(address(revertAccount), 10 ether);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(revertAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = keccak256("test");
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedMessageHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(address(revertEntryPoint));
        vm.expectRevert(SimpleAccount.SimpleAccount__PayPrefundFailed.selector);
        revertAccount.validateUserOp(userOp, userOpHash, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE/FALLBACK TESTS
    //////////////////////////////////////////////////////////////*/

    function testReceiveEther() public {
        uint256 initialBalance = address(account).balance;

        vm.deal(address(this), 1 ether);
        (bool success,) = address(account).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(address(account).balance, initialBalance + 1 ether);
    }

    function testFallbackFunction() public {
        uint256 initialBalance = address(account).balance;

        vm.deal(address(this), 1 ether);
        (bool success,) = address(account).call{value: 1 ether}("nonexistent");

        assertTrue(success);
        assertEq(address(account).balance, initialBalance + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetPenaltyChoice() public {
        assertEq(account.getPenaltyChoice(), 0);

        vm.prank(owner);
        account.setDelayPenalty(1 days);
        assertEq(account.getPenaltyChoice(), 1);
    }

    function testGetBuddy() public {
        assertEq(account.getBuddy(), address(0));

        vm.prank(owner);
        account.setBuddyPenalty(buddy);
        assertEq(account.getBuddy(), buddy);
    }

    function testGetDelayDuration() public {
        assertEq(account.getDelayDuration(), 0);

        vm.prank(owner);
        account.setDelayPenalty(1 days);
        assertEq(account.getDelayDuration(), 1 days);
    }
}

/*//////////////////////////////////////////////////////////////
                              HELPER CONTRACTS
//////////////////////////////////////////////////////////////*/

contract RevertOnReceive {
    receive() external payable {
        revert("Cannot receive ether");
    }

    fallback() external payable {
        revert("Cannot receive ether");
    }
}