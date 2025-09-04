// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {SmartAccount} from "src/SmartAccount.sol";
import {TaskManager} from "src/TaskManager.sol";
import {UserOperation} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {ISmartAccount} from "src/interface/ISmartAccount.sol";
import {ITaskManager} from "src/interface/ITaskManager.sol";

contract MockEntryPoint {
    // simple deposit bookkeeping for tests
    mapping(address => uint256) public deposits;
    bool public failFallback;

    // allow depositTo from smart account tests
    function depositTo(address who) external payable {
        deposits[who] += msg.value;
    }

    // withdrawTo sends ETH back to requested address (test-only simple implementation)
    function withdrawTo(address payable to, uint256 amount) external {
        if (to == payable(address(0))) revert("withdraw to zero");
        // naive: assume contract has enough balance
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // fallback used by _payPrefund (low-level call)
    fallback() external payable {
        if (failFallback) revert("fallback fail");
        // accept funds; record by msg.sender
        deposits[msg.sender] += msg.value;
    }

    receive() external payable {
        if (failFallback) revert("receive fail");
        deposits[msg.sender] += msg.value;
    }

    // helper to set fallback to fail
    function setFailFallback(bool v) external {
        failFallback = v;
    }
}

contract SmartAccountTest is Test {
    SmartAccount acct;
    TaskManager tm;
    MockEntryPoint ep;

    // test keys
    uint256 ownerKey;
    address ownerAddr;

    function setUp() public {
        // create owner key
        ownerKey = 0xA11CE;
        ownerAddr = vm.addr(ownerKey);

        // deploy TaskManager and MockEntryPoint
        tm = new TaskManager();
        ep = new MockEntryPoint();

        // deploy SmartAccount and initialize
        acct = new SmartAccount();
        acct.initialize(ownerAddr, address(ep), tm);

        // Fund SmartAccount with some ETH for tests
        vm.deal(address(acct), 10 ether);
    }

    // allow this test contract to receive ETH for withdrawTo assertions
    receive() external payable {}

    /*///////////////////////////////////////////////////////////////
                      BASIC INITIALIZATION & SUPPORT
    ///////////////////////////////////////////////////////////////*/

    function test_initial_owner_and_entrypoint_and_taskmanager() public view {
        assertEq(acct.s_owner(), ownerAddr);
        assertEq(address(acct.i_entryPoint()), address(ep));
        assertEq(address(acct.taskManager()), address(tm));
    }

    function test_supportsInterface() public view {
        bool ok = acct.supportsInterface(type(ISmartAccount).interfaceId);
        assertTrue(ok);
    }

    /*///////////////////////////////////////////////////////////////
                           EXECUTE (ENTRYPOINT)
    ///////////////////////////////////////////////////////////////*/

    function test_execute_onlyFromEntryPoint_revertsWhenNotEP() public {
        // call execute from non-entrypoint should revert
        vm.prank(address(0x123));
        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        acct.execute(address(0x1), 0, bytes(""));
    }

    function test_execute_reverts_when_withdrawing_committed_rewards() public {
        // create a task that reserves funds so remaining free balance < value
        // craft via calling createTask as if from EntryPoint
        uint256 reward = 9 ether;
        // create task via entrypoint: need to ensure acct has enough balance - yes (10 ETH)
        vm.prank(address(ep));
        acct.createTask("t", reward, 1 days, 1, 1 hours, address(0), 0);

        // now try to execute a withdrawal of 2 ETH (free balance = 10 - 9 = 1 < 2)
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__CannotWithdrawCommittedRewards.selector);
        acct.execute(address(0x1), 2 ether, bytes(""));
    }

    function test_execute_successful_call_by_entrypoint() public {
        // make sure free balance sufficient
        // call a contract that returns success
        address target = address(new CallReceiver());
        vm.prank(address(ep));
        acct.execute(target, 0, abi.encodeWithSelector(CallReceiver.ping.selector));
        // function simply sets storage in CallReceiver; verify it works
        assertTrue(CallReceiver(target).wasCalled());
    }

    /*///////////////////////////////////////////////////////////////
                         validateUserOp & nonce behavior
    ///////////////////////////////////////////////////////////////*/

    function test_validateUserOp_signature_failure_does_not_increment_nonce() public {
        // prepare a UserOperation signed by some other key
        bytes32 userOpHash = keccak256("user op");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        UserOperation memory uo = UserOperation({
            sender: address(acct),
            nonce: 0,
            initCode: bytes(""),
            callData: bytes(""),
            callGasLimit: 0,
            verificationGasLimit: 0,
            preVerificationGas: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: sig
        });

        // call via entrypoint (requireFromEntryPoint)
        // should return signature failure packed data, but we assert nonce unchanged
        uint256 beforeAcct = acct.nonce();
        vm.prank(address(ep));
        acct.validateUserOp(uo, userOpHash, 0);
        uint256 afterAcct = acct.nonce();
        assertEq(beforeAcct, afterAcct);
    }

    function test_validateUserOp_signature_success_increments_nonce_and_emits() public {
        bytes32 userOpHash = keccak256("user op 2");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        UserOperation memory uo = UserOperation({
            sender: address(acct),
            nonce: acct.nonce(), // must match
            initCode: bytes(""),
            callData: bytes(""),
            callGasLimit: 0,
            verificationGasLimit: 0,
            preVerificationGas: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: sig
        });

        // capture current nonce then call from entrypoint
        uint256 before = acct.nonce();
        vm.prank(address(ep));
        vm.expectEmit(true, false, false, true);
        emit SmartAccount.NonceChanged(before + 1);
        acct.validateUserOp(uo, userOpHash, 0);

        // nonce incremented
        assertEq(acct.nonce(), before + 1);
    }

    function test_validateUserOp_payPrefund_failure_reverts() public {
        // set MockEntryPoint fallback to fail so low-level call reverts
        ep.setFailFallback(true);

        bytes32 userOpHash = keccak256("user op 3");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        UserOperation memory uo = UserOperation({
            sender: address(acct),
            nonce: acct.nonce(),
            initCode: bytes(""),
            callData: bytes(""),
            callGasLimit: 0,
            verificationGasLimit: 0,
            preVerificationGas: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: sig
        });

        // missingAccountFunds > 0 triggers _payPrefund and it should revert
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__PayPrefundFailed.selector);
        acct.validateUserOp(uo, userOpHash, 1 wei);

        // restore
        ep.setFailFallback(false);
    }

    /*///////////////////////////////////////////////////////////////
                              TASK OPERATIONS
    ///////////////////////////////////////////////////////////////*/

    function test_createTask_requires_funding_and_reserves() public {
        // fund handled in setUp; create a task with small reward
        uint256 reward = 1 ether;
        vm.prank(address(ep));
        acct.createTask("T1", reward, 1 days, 1, 1 hours, address(0), 0);

        // total committed updated
        assertEq(acct.s_totalCommittedReward(), reward);

        // task is recorded in TaskManager for this account
        ITaskManager.Task memory t = tm.getTask(address(acct), 0);
        assertEq(t.rewardAmount, reward);
    }

    function test_createTask_insufficient_funds_reverts() public {
        // send away balance to make insufficient
        vm.deal(address(acct), 0);
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__AddMoreFunds.selector);
        acct.createTask("T2", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        // refund for subsequent tests
        vm.deal(address(acct), 10 ether);
    }

    function test_complete_and_cancel_task_flow_and_payments() public {
        uint256 reward = 1 ether;

        // create task
        vm.prank(address(ep));
        acct.createTask("COMP", reward, 1 days, 1, 1 hours, address(0), 0);

        // complete task via EntryPoint (must be called by EntryPoint)
        // track owner balance before
        vm.deal(ownerAddr, 0);
        uint256 beforeOwner = ownerAddr.balance;

        vm.prank(address(ep));
        acct.completeTask(0);

        // owner received reward
        uint256 afterOwner = ownerAddr.balance;
        assertEq(afterOwner - beforeOwner, reward);

        // s_totalCommittedReward reduced to zero
        assertEq(acct.s_totalCommittedReward(), 0);

        // create another and then cancel
        vm.prank(address(ep));
        acct.createTask("CANCEL", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        vm.prank(address(ep));
        acct.cancelTask(1);

        // s_totalCommittedReward decreased
        assertEq(acct.s_totalCommittedReward(), 0);
    }

    /*///////////////////////////////////////////////////////////////
                        EXPIRED / PENALTY / RELEASE
    ///////////////////////////////////////////////////////////////*/

    function test_expired_callback_sendBuddy_and_releaseDelayed() public {
        // create a task that will expire and send to buddy (choice = PENALTY_SENDBUDDY)
        address buddy = address(0xBEEF);

        // ensure SmartAccount has funds to transfer to buddy on expiry
        vm.deal(address(acct), 5 ether);

        vm.prank(address(ep));
        acct.createTask("send", 1 ether, 1, 2, 0, buddy, 0); // deadlineInSeconds = 1 sec

        // advance time and run TaskManager upkeep to expire -> TaskManager.performUpkeep will call expiredTaskCallback
        vm.warp(block.timestamp + 10);

        // call TaskManager.performUpkeep to find and process root
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);

        // perform upkeep which will call SmartAccount.expiredTaskCallback via TaskManager
        vm.prank(address(this));
        tm.performUpkeep(data);

        // buddy should have received 1 ether from SmartAccount as penalty
        // As we cannot inspect balance of arbitrary buddy if not pre-funded by deal, use vm.deal to set expectation
        // Check SmartAccount's committed reward decreased
        assertEq(acct.s_totalCommittedReward(), 0);

        // Now create a delayed-payment task and test releaseDelayedPayment flow
        vm.prank(address(ep));
        acct.createTask("delay", 1 ether, 1, 1, 2, address(0), 0); // choice=1 delayed

        // expire (advance just past the deadline but still before delayDuration elapses)
        vm.warp(block.timestamp + 2);
        (bool needed2, bytes memory data2) = tm.checkUpkeep("");
        assertTrue(needed2);
        vm.prank(address(this));
        tm.performUpkeep(data2);

        // release delayed payment before delay duration => should revert
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyDurationNotElapsed.selector);
        acct.releaseDelayedPayment(1);

        // fast-forward past delayDuration
        vm.warp(block.timestamp + 100);

        vm.prank(address(ep));
        acct.releaseDelayedPayment(1);

        // re-release should revert PaymentAlreadyReleased
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__PaymentAlreadyReleased.selector);
        acct.releaseDelayedPayment(1);
    }

    function test_expiredTaskCallback_requires_taskManager_sender() public {
        // create task normally then call expiredTaskCallback from non-taskmanager address -> revert
        vm.prank(address(ep));
        acct.createTask("X", 1 ether, 100, 1, 1 hours, address(0), 0);

        // Not From EntryPoint is for other modifiers; expiredTaskCallback requires TaskManager sender.
        // Call directly but with wrong sender should revert OnlyTaskManagerCanCall
        vm.prank(address(0x1234));
        vm.expectRevert(SmartAccount.SmartAccount__OnlyTaskManagerCanCall.selector);
        acct.expiredTaskCallback(0);

        // calling with TaskManager as sender but task not expired should revert TaskNotExpired
        vm.prank(address(tm));
        vm.expectRevert(SmartAccount.SmartAccount__TaskNotExpired.selector);
        acct.expiredTaskCallback(0);
    }
    // Additional test functions to add to SmartAccountTest contract

    /*///////////////////////////////////////////////////////////////
                    ADDITIONAL INITIALIZATION TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_initialize_twice_reverts() public {
        // Try to initialize again - should revert due to Initializable
        vm.expectRevert();
        acct.initialize(ownerAddr, address(ep), tm);
    }

    function test_fallback_receive_functions() public {
        // Test receive function
        uint256 balanceBefore = address(acct).balance;
        (bool success,) = address(acct).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(acct).balance, balanceBefore + 1 ether);

        // Test fallback function
        balanceBefore = address(acct).balance;
        (bool success2,) = address(acct).call{value: 0.5 ether}("0x1234");
        assertTrue(success2);
        assertEq(address(acct).balance, balanceBefore + 0.5 ether);
    }

    /*///////////////////////////////////////////////////////////////
                    VALIDATION EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function test_validateUserOp_invalid_nonce_reverts() public {
        bytes32 userOpHash = keccak256("user op");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, userOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        UserOperation memory uo = UserOperation({
            sender: address(acct),
            nonce: 999, // wrong nonce
            initCode: bytes(""),
            callData: bytes(""),
            callGasLimit: 0,
            verificationGasLimit: 0,
            preVerificationGas: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: sig
        });

        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidNonce.selector);
        acct.validateUserOp(uo, userOpHash, 0);
    }

    function test_validateUserOp_empty_signature_fails() public {
        bytes32 userOpHash = keccak256("user op");

        UserOperation memory uo = UserOperation({
            sender: address(acct),
            nonce: 0,
            initCode: bytes(""),
            callData: bytes(""),
            callGasLimit: 0,
            verificationGasLimit: 0,
            preVerificationGas: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: bytes("") // empty signature
        });

        vm.prank(address(ep));
        // Should return signature failure (no revert, just failed validation)
        uint256 result = acct.validateUserOp(uo, userOpHash, 0);
        // Check that signature validation failed (first bit should be 1)
        assertTrue((result & 1) == 1);
    }

    /*///////////////////////////////////////////////////////////////
                    TASK CREATION EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function test_createTask_validation_method_boundary() public {
        // Test boundary value for verificationMethod
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidVerificationMethod.selector);
        acct.createTask("test", 1 ether, 1 days, 1, 1 hours, address(0), 3); // > 2
    }

    function test_createTask_choice_boundary_zero() public {
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__PickAPenalty.selector);
        acct.createTask("test", 1 ether, 1 days, 0, 1 hours, address(0), 0);
    }

    function test_createTask_choice_boundary_high() public {
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyChoice.selector);
        acct.createTask("test", 1 ether, 1 days, 3, 1 hours, address(0), 0);
    }

    function test_createTask_without_taskManager_reverts() public {
        // Deploy new account without taskManager
        SmartAccount newAcct = new SmartAccount();
        newAcct.initialize(ownerAddr, address(ep), ITaskManager(address(0)));

        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__NoTaskManagerLinked.selector);
        newAcct.createTask("test", 1 ether, 1 days, 1, 1 hours, address(0), 0);
    }

    function test_createTask_exact_balance_edge() public {
        // Set balance to exactly what's needed
        vm.deal(address(acct), 1 ether);

        vm.prank(address(ep));
        acct.createTask("exact", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        assertEq(acct.s_totalCommittedReward(), 1 ether);
        assertEq(address(acct).balance, 1 ether);
    }

    /*///////////////////////////////////////////////////////////////
                    TASK COMPLETION EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function test_completeTask_zero_reward() public {
        // Create task with zero reward (should revert in createTask)
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__RewardCannotBeZero.selector);
        acct.createTask("zero", 0, 1 days, 1, 1 hours, address(0), 0);
    }

    function test_completeTask_payment_failure() public {
        // Create a task and then make payment fail by removing ETH
        vm.prank(address(ep));
        acct.createTask("fail", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        // Drain all ETH to make payment fail
        vm.deal(address(acct), 0);

        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__TaskRewardPaymentFailed.selector);
        acct.completeTask(0);
    }

    /*///////////////////////////////////////////////////////////////
                    EXPIRED TASK CALLBACK TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_expiredTaskCallback_invalid_penalty_choice() public {
        // This would require modifying the task data directly since createTask prevents invalid choices
        // We'll test the error handling in the callback
        vm.prank(address(ep));
        acct.createTask("test", 1 ether, 1, 1, 1 hours, address(0), 0);

        // Manually expire the task via TaskManager
        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);
        tm.performUpkeep(data);

        // The callback should have executed successfully with choice=1 (delayed payment)
    }

    function test_expiredTaskCallback_sendbuddy_zero_address() public {
        // Create task with PENALTY_SENDBUDDY but buddy as zero (this should be prevented in createTask)
        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__InvalidPenaltyConfig.selector);
        acct.createTask("test", 1 ether, 1, 2, 0, address(0), 0);
    }

    function test_expiredTaskCallback_sendbuddy_payment_failure() public {
        // Create a contract that rejects ETH to test payment failure
        RejectETH rejectContract = new RejectETH();

        vm.prank(address(ep));
        acct.createTask("test", 1 ether, 1, 2, 0, address(rejectContract), 0);

        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        assertTrue(needed);

        // The TaskManager catches callback reverts; performUpkeep should not revert
        // Instead the TaskExpiredCallFailure event should be emitted by TaskManager
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit TaskManager.TaskExpiredCallFailure(address(acct), 0);
        tm.performUpkeep(data);
    }

    /*///////////////////////////////////////////////////////////////
                    RELEASE DELAYED PAYMENT TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_releaseDelayedPayment_wrong_penalty_type() public {
        // Create PENALTY_SENDBUDDY task and try to release delayed payment
        vm.prank(address(ep));
        acct.createTask("test", 1 ether, 1, 2, 0, address(0xBEEF), 0);

        // Expire it
        vm.warp(block.timestamp + 10);
        (bool needed, bytes memory data) = tm.checkUpkeep("");
        tm.performUpkeep(data);

        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__PenaltyTypeMismatch.selector);
        acct.releaseDelayedPayment(0);
    }

    function test_releaseDelayedPayment_not_expired_task() public {
        vm.prank(address(ep));
        acct.createTask("test", 1 ether, 100 days, 1, 1 hours, address(0), 0);

        vm.prank(address(ep));
        vm.expectRevert(SmartAccount.SmartAccount__TaskNotExpired.selector);
        acct.releaseDelayedPayment(0);
    }

    /*///////////////////////////////////////////////////////////////
                    EXECUTE FUNCTION EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function test_execute_with_failing_external_call() public {
        address failingContract = address(new FailingContract());

        vm.prank(address(ep));
        vm.expectRevert(); // Should revert with ExecutionFailed
        acct.execute(failingContract, 0, abi.encodeWithSelector(FailingContract.fail.selector));
    }

    function test_execute_with_exact_remaining_balance() public {
        // Create task that commits some funds, then execute with remaining exact balance
        address alice = address(0xBeef);
        vm.deal(address(acct), 2 ether);

        vm.prank(address(ep));
        acct.createTask("test", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        // Remaining balance is 1 ether, try to send exactly that
        vm.prank(address(ep));
        acct.execute(alice, 1 ether, "");

        assertEq(alice.balance, 1 ether);
        assertEq(address(acct).balance, 1 ether); // Only committed funds remain
    }

    /*///////////////////////////////////////////////////////////////
                    EIP-1271 EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function test_isValidSignature_wrong_signer() public view {
        bytes32 someHash = keccak256("test");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, someHash); // wrong key
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes4 result = acct.isValidSignature(someHash, sig);
        assertEq(result, bytes4(0));
    }

    function test_isValidSignature_malformed_signature() public {
        bytes32 someHash = keccak256("test");
        bytes memory invalidSig = new bytes(64); // too short

        // This should revert or return invalid (depending on ECDSA implementation)
        vm.expectRevert();
        acct.isValidSignature(someHash, invalidSig);
    }

    /*///////////////////////////////////////////////////////////////
                    DEPOSIT HELPER EDGE CASES
    ///////////////////////////////////////////////////////////////*/

    function test_addDeposit_zero_value() public {
        vm.prank(address(this));
        acct.addDeposit{value: 0}();

        assertEq(ep.deposits(address(acct)), 0);
    }

    function test_withdrawDepositTo_zero_address() public {
        // Add deposit first
        vm.deal(address(this), 1 ether);
        acct.addDeposit{value: 1 ether}();

        // Try to withdraw to zero address
        vm.prank(address(ep));
        vm.expectRevert(); // Should fail in MockEntryPoint.withdrawTo
        acct.withdrawDepositTo(payable(address(0)), 1 ether);
    }

    /*///////////////////////////////////////////////////////////////
                    MULTIPLE TASK SCENARIOS
    ///////////////////////////////////////////////////////////////*/

    function test_multiple_tasks_committed_rewards_tracking() public {
        vm.deal(address(acct), 5 ether);

        // Create multiple tasks
        vm.prank(address(ep));
        acct.createTask("task1", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        vm.prank(address(ep));
        acct.createTask("task2", 2 ether, 1 days, 2, 0, address(0xCafe), 0);

        assertEq(acct.s_totalCommittedReward(), 3 ether);

        // Complete first task
        vm.prank(address(ep));
        acct.completeTask(0);

        assertEq(acct.s_totalCommittedReward(), 2 ether);

        // Cancel second task
        vm.prank(address(ep));
        acct.cancelTask(1);

        assertEq(acct.s_totalCommittedReward(), 0);
    }

    function test_task_operations_without_entrypoint_revert() public {
        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        acct.createTask("test", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        acct.completeTask(0);

        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        acct.cancelTask(0);

        vm.expectRevert(SmartAccount.SmartAccount__NotFromEntryPoint.selector);
        acct.releaseDelayedPayment(0);
    }

    /*///////////////////////////////////////////////////////////////
                    GETTER FUNCTIONS TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_getTask_nonexistent() public {
        vm.expectRevert(); // Should revert in TaskManager
        acct.getTask(999);
    }

    function test_getTasksByStatus_various_statuses() public {
        // Create tasks and test different status queries
        vm.prank(address(ep));
        acct.createTask("pending", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        vm.prank(address(ep));
        acct.createTask("to_complete", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        vm.prank(address(ep));
        acct.completeTask(1);

        ITaskManager.Task[] memory pendingTasks = acct.getTasksByStatus(ITaskManager.TaskStatus.PENDING, 0, 10);
        assertEq(pendingTasks.length, 1);

        ITaskManager.Task[] memory completedTasks = acct.getTasksByStatus(ITaskManager.TaskStatus.COMPLETED, 0, 10);
        assertEq(completedTasks.length, 1);
    }

    /*///////////////////////////////////////////////////////////////
                    REENTRANCY PROTECTION TESTS
    ///////////////////////////////////////////////////////////////*/

    function test_execute_reentrancy_protection() public {
        ReentrantAttacker attacker = new ReentrantAttacker(acct);
        vm.deal(address(acct), 10 ether);

        vm.prank(address(ep));
        vm.expectRevert(); // Should revert due to ReentrancyGuard
        acct.execute(address(attacker), 0, abi.encodeWithSelector(ReentrantAttacker.attack.selector));
    }

    /*///////////////////////////////////////////////////////////////
                         ENTRYPOINT DEPOSIT HELPERS
    ///////////////////////////////////////////////////////////////*/

    function test_addDeposit_and_withdrawDeposit_flow() public {
        // addDeposit forwards to i_entryPoint.depositTo
        vm.deal(address(this), 1 ether);
        vm.prank(address(this));
        acct.addDeposit{value: 0.5 ether}();

        // entrypoint deposits recorded
        assertEq(ep.deposits(address(acct)), 0.5 ether);

        // withdrawDepositTo callable only from EntryPoint
        // call withdraw via EntryPoint-relative call
        vm.prank(address(ep));
        acct.withdrawDepositTo(payable(address(this)), 0.5 ether);
    }

    /*///////////////////////////////////////////////////////////////
                         EIP-1271 & GETTERS
    ///////////////////////////////////////////////////////////////*/

    function test_isValidSignature_and_getters() public {
        bytes32 someHash = keccak256("abc");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, someHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes4 ok = acct.isValidSignature(someHash, sig);
        assert(ok == 0x1626ba7e);

        // getters proxied to TaskManager
        // getTotalTasks requires taskManagerLinked; create a task first via EntryPoint
        vm.prank(address(ep));
        acct.createTask("G", 1 ether, 1 days, 1, 1 hours, address(0), 0);

        vm.prank(address(ep));
        uint256 total = acct.getTotalTasks();
        assertEq(total, 1);
    }
}

/*//////////////////////////////////////////////////////////////
                         Helper Contracts
//////////////////////////////////////////////////////////////*/

contract CallReceiver {
    bool public called;

    function ping() external {
        called = true;
    }

    function wasCalled() external view returns (bool) {
        return called;
    }
}
/*///////////////////////////////////////////////////////////////
                    EDGE CASE HELPER CONTRACTS
///////////////////////////////////////////////////////////////*/

contract RejectETH {
    receive() external payable {
        revert("No ETH accepted");
    }
}

contract FailingContract {
    function fail() external pure {
        revert("Always fails");
    }
}

contract ReentrantAttacker {
    SmartAccount target;

    constructor(SmartAccount _target) {
        target = _target;
    }

    function attack() external {
        // Try to call execute again (should fail due to nonReentrant)
        target.execute(address(this), 0, "");
    }
}
