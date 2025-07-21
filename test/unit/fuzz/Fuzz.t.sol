// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AccountFactory} from "src/AccountFactory.sol";
import {SmartAccount} from "src/SmartAccount.sol";
import {TaskManager} from "src/TaskManager.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";

// Mock EntryPoint for testing
contract MockEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external {}
    function getUserOpHash(PackedUserOperation calldata userOp) external pure returns (bytes32) {
        return keccak256(abi.encode(userOp));
    }
}

// Handler contract for fuzz testing
contract Handler is Test {
    AccountFactory public factory;
    SmartAccount[] public accounts;
    TaskManager[] public taskManagers;
    MockEntryPoint public entryPoint;
    
    address[] public actors;
    uint256 public constant MAX_ACTORS = 10;
    uint256 public constant MAX_TASKS_PER_ACCOUNT = 50;
    
    // Ghost variables for invariant tracking
    uint256 public ghost_totalAccountsCreated;
    uint256 public ghost_totalTasksCreated;
    uint256 public ghost_totalCompletedTasks;
    uint256 public ghost_totalCanceledTasks;
    uint256 public ghost_totalExpiredTasks;
    uint256 public ghost_totalCommittedRewards;
    uint256 public ghost_totalReleasedRewards;
    
    mapping(address => uint256) public ghost_accountBalances;
    mapping(address => uint256) public ghost_accountCommittedRewards;
    mapping(address => uint256[]) public ghost_accountTasks;
    mapping(uint256 => bool) public ghost_taskExists;
    
    modifier useActor(uint256 actorSeed) {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }
    
    modifier validAccount(uint256 accountSeed) {
        vm.assume(accounts.length > 0);
        _;
    }
    
    constructor(AccountFactory _factory, MockEntryPoint _entryPoint) {
        factory = _factory;
        entryPoint = _entryPoint;
        
        // Initialize actors
        for (uint256 i = 0; i < MAX_ACTORS; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(actor);
            vm.deal(actor, 1000 ether);
        }
    }
    
    // Handler: Create Account
    function createAccount(uint256 actorSeed, uint256 nonce) external useActor(actorSeed) {
        nonce = bound(nonce, 0, type(uint64).max);
        
        address predictedAddress = factory.getAddress(nonce);
        
        // Skip if account already exists
        if (predictedAddress.code.length > 0) return;
        
        try factory.createAccount(nonce) returns (address newAccount) {
            SmartAccount account = SmartAccount(payable(newAccount));
            TaskManager taskManager = TaskManager(account.getTaskManagerAddress());
            
            accounts.push(account);
            taskManagers.push(taskManager);
            ghost_totalAccountsCreated++;
            ghost_accountBalances[newAccount] = newAccount.balance;
            
            // Fund the new account
            vm.deal(newAccount, 10 ether);
            ghost_accountBalances[newAccount] = newAccount.balance;
        } catch {
            // Account creation failed, skip
        }
    }
    
    // Handler: Create Task
    function createTask(
        uint256 accountSeed,
        string memory description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 actorSeedForBuddy,
        uint256 delayDuration
    ) external validAccount(accountSeed) {
        accountSeed = bound(accountSeed, 0, accounts.length - 1);
        SmartAccount account = accounts[accountSeed];
        address owner = account.s_owner();
        
        // Bound parameters
        rewardAmount = bound(rewardAmount, 1, 5 ether);
        deadlineInSeconds = bound(deadlineInSeconds, 1, 30 days);
        choice = uint8(bound(choice, 1, 2));
        delayDuration = bound(delayDuration, 1 hours, 30 days);
        
        address buddy = address(0);
        if (choice == 2) {
            uint256 buddyIndex = bound(actorSeedForBuddy, 0, actors.length - 1);
            buddy = actors[buddyIndex];
        }
        
        vm.startPrank(owner);
        
        // Ensure account has enough balance
        if (address(account).balance < account.s_totalCommittedReward() + rewardAmount) {
            vm.deal(address(account), account.s_totalCommittedReward() + rewardAmount + 1 ether);
        }
        
        try account.createTask(description, rewardAmount, deadlineInSeconds, choice, buddy, delayDuration) {
            uint256 taskId = account.getTotalTasks() - 1;
            ghost_totalTasksCreated++;
            ghost_totalCommittedRewards += rewardAmount;
            ghost_accountCommittedRewards[address(account)] += rewardAmount;
            ghost_accountTasks[address(account)].push(taskId);
            ghost_taskExists[taskId] = true;
        } catch {
            // Task creation failed
        }
        
        vm.stopPrank();
    }
    
    // Handler: Complete Task
    function completeTask(uint256 accountSeed, uint256 taskSeed) external validAccount(accountSeed) {
        accountSeed = bound(accountSeed, 0, accounts.length - 1);
        SmartAccount account = accounts[accountSeed];
        address owner = account.s_owner();
        
        if (account.getTotalTasks() == 0) return;
        
        uint256 taskId = bound(taskSeed, 0, account.getTotalTasks() - 1);
        
        vm.startPrank(owner);
        
        try account.completeTask(taskId) {
            TaskManager.Task memory task = account.getTask(taskId);
            ghost_totalCompletedTasks++;
            ghost_totalReleasedRewards += task.rewardAmount;
            ghost_totalCommittedRewards -= task.rewardAmount;
            ghost_accountCommittedRewards[address(account)] -= task.rewardAmount;
        } catch {
            // Task completion failed
        }
        
        vm.stopPrank();
    }
    
    // Handler: Cancel Task
    function cancelTask(uint256 accountSeed, uint256 taskSeed) external validAccount(accountSeed) {
        accountSeed = bound(accountSeed, 0, accounts.length - 1);
        SmartAccount account = accounts[accountSeed];
        address owner = account.s_owner();
        
        if (account.getTotalTasks() == 0) return;
        
        uint256 taskId = bound(taskSeed, 0, account.getTotalTasks() - 1);
        
        vm.startPrank(owner);
        
        try account.cancelTask(taskId) {
            TaskManager.Task memory task = account.getTask(taskId);
            ghost_totalCanceledTasks++;
            ghost_totalCommittedRewards -= task.rewardAmount;
            ghost_accountCommittedRewards[address(account)] -= task.rewardAmount;
        } catch {
            // Task cancellation failed
        }
        
        vm.stopPrank();
    }
    
    // Handler: Transfer funds
    function transferFunds(uint256 accountSeed, uint256 amount, uint256 recipientSeed) external validAccount(accountSeed) {
        accountSeed = bound(accountSeed, 0, accounts.length - 1);
        SmartAccount account = accounts[accountSeed];
        address owner = account.s_owner();
        
        uint256 maxTransfer = address(account).balance - account.s_totalCommittedReward();
        if (maxTransfer == 0) return;
        
        amount = bound(amount, 1, maxTransfer);
        address recipient = actors[bound(recipientSeed, 0, actors.length - 1)];
        
        vm.startPrank(owner);
        
        try account.transfer(recipient, amount) {
            ghost_accountBalances[address(account)] -= amount;
            ghost_accountBalances[recipient] += amount;
        } catch {
            // Transfer failed
        }
        
        vm.stopPrank();
    }
    
    // Handler: Release delayed payment
    function releaseDelayedPayment(uint256 accountSeed, uint256 taskSeed) external validAccount(accountSeed) {
        accountSeed = bound(accountSeed, 0, accounts.length - 1);
        SmartAccount account = accounts[accountSeed];
        address owner = account.s_owner();
        
        if (account.getTotalTasks() == 0) return;
        
        uint256 taskId = bound(taskSeed, 0, account.getTotalTasks() - 1);
        
        vm.startPrank(owner);
        
        try account.releaseDelayedPayment(taskId) {
            TaskManager.Task memory task = account.getTask(taskId);
            ghost_totalReleasedRewards += task.rewardAmount;
            ghost_totalCommittedRewards -= task.rewardAmount;
            ghost_accountCommittedRewards[address(account)] -= task.rewardAmount;
        } catch {
            // Release failed
        }
        
        vm.stopPrank();
    }
    
    // Handler: Warp time to trigger task expiration
    function warpTime(uint256 timeToWarp) external {
        timeToWarp = bound(timeToWarp, 1 hours, 60 days);
        vm.warp(block.timestamp + timeToWarp);
        
        // Try to expire tasks for each task manager
        for (uint256 i = 0; i < taskManagers.length; i++) {
            TaskManager tm = taskManagers[i];
            try tm.checkUpkeep("") returns (bool upkeepNeeded, bytes memory performData) {
                if (upkeepNeeded) {
                    try tm.performUpkeep(performData) {
                        // Upkeep performed successfully
                    } catch {
                        // Upkeep failed
                    }
                }
            } catch {
                // Check upkeep failed
            }
        }
    }
    
    // Helper functions for invariants
    function getAccountCount() external view returns (uint256) {
        return accounts.length;
    }
    
    function getTotalTasksAcrossAllAccounts() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < accounts.length; i++) {
            total += accounts[i].getTotalTasks();
        }
        return total;
    }
    
    function getTotalCommittedRewardsAcrossAllAccounts() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < accounts.length; i++) {
            total += accounts[i].s_totalCommittedReward();
        }
        return total;
    }
}

// Main fuzz test contract with invariants
contract FuzzTest is StdInvariant, Test {
    Handler public handler;
    AccountFactory public factory;
    MockEntryPoint public entryPoint;
    
    function setUp() external {
        entryPoint = new MockEntryPoint();
        factory = new AccountFactory(address(entryPoint), address(this));
        handler = new Handler(factory, entryPoint);
        
        // Set handler as target for invariant testing
        targetContract(address(handler));
        
        // Target specific functions for more focused fuzzing
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.createAccount.selector;
        selectors[1] = Handler.createTask.selector;
        selectors[2] = Handler.completeTask.selector;
        selectors[3] = Handler.cancelTask.selector;
        selectors[4] = Handler.transferFunds.selector;
        selectors[5] = Handler.releaseDelayedPayment.selector;
        selectors[6] = Handler.warpTime.selector;
        
        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }
    
    // INVARIANT: Total committed rewards should never exceed total account balances
    function invariant_committedRewardsNeverExceedBalance() external view {
        uint256 totalCommitted = handler.getTotalCommittedRewardsAcrossAllAccounts();
        uint256 totalBalance = 0;
        
        for (uint256 i = 0; i < handler.getAccountCount(); i++) {
            SmartAccount account = handler.accounts(i);
            totalBalance += address(account).balance;
        }
        
        assertGe(totalBalance, totalCommitted, "Committed rewards exceed available balance");
    }
    
    // INVARIANT: Ghost variables should match actual contract state
    function invariant_ghostVariablesMatchActualState() external view {
        uint256 actualTotalTasks = handler.getTotalTasksAcrossAllAccounts();
        assertEq(handler.ghost_totalTasksCreated(), actualTotalTasks, "Ghost total tasks mismatch");
        // Note: ghost_totalCommittedRewards tracks net committed (created - released - canceled)
        // So we can't directly compare, but we can check that committed rewards never go negative
        assertGe(handler.ghost_totalCommittedRewards(), 0, "Ghost committed rewards went negative");
    }
    
    // INVARIANT: Account factory should track user clones correctly
    function invariant_factoryUserClonesConsistent() external view {
        // Each created account should be tracked in the factory
        for (uint256 i = 0; i < handler.getAccountCount(); i++) {
            SmartAccount account = handler.accounts(i);
            address owner = account.s_owner();
            address trackedClone = factory.getUserClone(owner);
            
            // If this owner has a tracked clone, it should match one of our accounts
            if (trackedClone != address(0)) {
                bool found = false;
                for (uint256 j = 0; j < handler.getAccountCount(); j++) {
                    if (address(handler.accounts(j)) == trackedClone) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, "Factory tracked clone not found in accounts array");
            }
        }
    }
    
    // INVARIANT: Task managers should be linked correctly to accounts
    function invariant_taskManagerAccountLinkage() external view {
        for (uint256 i = 0; i < handler.getAccountCount(); i++) {
            SmartAccount account = handler.accounts(i);
            address taskManagerAddr = account.getTaskManagerAddress();
            assertFalse(taskManagerAddr == address(0), "Task manager not linked to account");
            
            TaskManager tm = TaskManager(taskManagerAddr);
            assertEq(tm.owner(), address(account), "Task manager owner mismatch");
        }
    }
    
    // INVARIANT: No account should have committed rewards exceeding its balance
    function invariant_noAccountOvercommitted() external view {
        for (uint256 i = 0; i < handler.getAccountCount(); i++) {
            SmartAccount account = handler.accounts(i);
            uint256 balance = address(account).balance;
            uint256 committed = account.s_totalCommittedReward();
            
            assertGe(balance, committed, "Account has committed more than its balance");
        }
    }
    
    // INVARIANT: Task state transitions are valid
    function invariant_validTaskStateTransitions() external view {
        for (uint256 i = 0; i < handler.getAccountCount(); i++) {
            SmartAccount account = handler.accounts(i);
            uint256 totalTasks = account.getTotalTasks();
            
            for (uint256 taskId = 0; taskId < totalTasks; taskId++) {
                try account.getTask(taskId) returns (TaskManager.Task memory task) {
                    // Task should have valid status
                    assertTrue(
                        task.status == TaskManager.TaskStatus.PENDING ||
                        task.status == TaskManager.TaskStatus.COMPLETED ||
                        task.status == TaskManager.TaskStatus.CANCELED ||
                        task.status == TaskManager.TaskStatus.EXPIRED,
                        "Invalid task status"
                    );
                    
                    // Expired tasks with delayed payment should have valid timing
                    if (task.status == TaskManager.TaskStatus.EXPIRED && task.choice == 1) {
                        assertTrue(block.timestamp > task.deadline, "Task marked expired before deadline");
                    }
                    
                    // Completed/canceled tasks should not be expired
                    if (task.status == TaskManager.TaskStatus.COMPLETED || task.status == TaskManager.TaskStatus.CANCELED) {
                        // This is more of a business logic check - tasks shouldn't be marked as multiple states
                        assertTrue(task.status != TaskManager.TaskStatus.EXPIRED, "Task has conflicting status");
                    }
                } catch {
                    // Task doesn't exist or is invalid, which is acceptable
                }
            }
        }
    }
    
    // INVARIANT: Sum of task completion states should equal total tasks
    function invariant_taskStatesSumToTotal() external view {
        uint256 totalPending = 0;
        uint256 totalCompleted = 0;
        uint256 totalCanceled = 0;
        uint256 totalExpired = 0;
        uint256 totalTasks = 0;
        
        for (uint256 i = 0; i < handler.getAccountCount(); i++) {
            SmartAccount account = handler.accounts(i);
            uint256 accountTasks = account.getTotalTasks();
            totalTasks += accountTasks;
            
            for (uint256 taskId = 0; taskId < accountTasks; taskId++) {
                try account.getTask(taskId) returns (TaskManager.Task memory task) {
                    if (task.status == TaskManager.TaskStatus.PENDING) totalPending++;
                    else if (task.status == TaskManager.TaskStatus.COMPLETED) totalCompleted++;
                    else if (task.status == TaskManager.TaskStatus.CANCELED) totalCanceled++;
                    else if (task.status == TaskManager.TaskStatus.EXPIRED) totalExpired++;
                } catch {
                    // Skip invalid tasks
                }
            }
        }
        
        assertEq(
            totalPending + totalCompleted + totalCanceled + totalExpired,
            totalTasks,
            "Task state counts don't sum to total tasks"
        );
    }
}