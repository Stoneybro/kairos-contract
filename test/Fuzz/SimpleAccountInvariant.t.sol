// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console2} from "forge-std/Test.sol";
import {SimpleAccount} from "src/SimpleAccount.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {TaskManager} from "src/TaskManager.sol";
import {SimpleAccountFuzzHandler} from "test/Fuzz/SimpleAccountFuzzHandler.t.sol";

contract SimpleAccountInvariant is StdInvariant, Test {
    SimpleAccount account;
    uint256 ownerPrivateKey = 1;
    address owner = vm.addr(ownerPrivateKey);
    address attacker = makeAddr("ATTACKER");
    address buddy = address(0xBEEF);
    HelperConfig newConfig;
    HelperConfig.NetworkConfig config;
    TaskManager taskManager;
    SimpleAccountFuzzHandler handler;

    function setUp() public {
        // Initialize config first
        newConfig = new HelperConfig();
        config = newConfig.getConfig();
        
        // Create and initialize account
        account = new SimpleAccount();
        account.initialize(owner, address(config.entryPoint));
        vm.deal(address(account), 10 ether);
        
        // Create and link task manager
        taskManager = new TaskManager(address(account));
        vm.prank(owner);
        account.linkTaskManager(address(taskManager));
        
        // Set up penalty mechanism (required before creating tasks)
        vm.startPrank(owner);
        account.setDelayPenalty(1 days); // Set delay penalty
        vm.stopPrank();
        
        // Create handler and set as target
        handler = new SimpleAccountFuzzHandler(owner, account, taskManager, config);
        targetContract(address(handler));
    }

    function invariant_AccountBalanceShouldBeGreaterThanOrEqualToCommitedRewards() public view {
        uint256 balance = address(account).balance;
        uint256 committed = account.s_totalCommittedReward();
        
        console2.log("Account balance:", balance);
        console2.log("Total committed rewards:", committed);
        
        assert(balance >= committed);
    }

    function invariant_NoNegativeCommittedRewards() public view {
        uint256 committed = account.s_totalCommittedReward();
        console2.log("Committed rewards:", committed);
        
        // In Solidity, uint256 cannot be negative, but we check for consistency
        assert(committed >= 0);
    }

    function invariant_SumOfAllActiveRewardsShouldEqualTotalCommitedRewards() public view {
        uint256 activeRewards = account.getSumOfActiveTasksRewards();
        uint256 totalCommitted = account.s_totalCommittedReward();
        
        console2.log("Active rewards sum:", activeRewards);
        console2.log("Total committed:", totalCommitted);
        console2.log("Handler task counter:", handler.taskCounter());
        
        assert(activeRewards == totalCommitted);
    }

    function invariant_TaskManagerIsCorrectlyLinked() public view {
        address linkedTaskManager = address(account.taskManager());
        console2.log("Linked task manager:", linkedTaskManager);
        console2.log("Expected task manager:", address(taskManager));
        
        assert(linkedTaskManager == address(taskManager));
        assert(account.isLinkedTaskManager(address(taskManager)));
    }

    function invariant_HandlerActiveTasksConsistency() public view {
        uint256 handlerActiveCount = handler.getActiveTaskCount();
        uint256 totalCreated = handler.taskCounter();
        
        console2.log("Handler active tasks:", handlerActiveCount);
        console2.log("Total tasks created:", totalCreated);
        
        // Active tasks should never exceed total tasks created
        assert(handlerActiveCount <= totalCreated);
    }
}