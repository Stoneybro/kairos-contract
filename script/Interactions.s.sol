// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccountFactory} from "src/AccountFactory.sol";
import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MessageHashUtils} from "lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {SimpleAccount} from "src/SimpleAccount.sol";

/**
 * @title Complete Flow Test Script
 * @notice Tests the entire user journey from account creation to task management
 */
contract CompleteFlowTest is Script {
    using MessageHashUtils for bytes32;
    
    // Configuration
    HelperConfig.NetworkConfig config;
    AccountFactory factory;
    SimpleAccount smartAccount;
    address owner;
    uint256 ownerPrivateKey;
    
    function setUp() public {
        // Set up configuration
        HelperConfig configHelper = new HelperConfig();
        config = configHelper.getConfig();
        
        // Use different accounts for different networks
        if (block.chainid == 31337) { // Anvil
            ownerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil account[0]
            owner = vm.addr(ownerPrivateKey);
        } else {
            ownerPrivateKey = vm.envUint("PRIVATE_KEY");
            owner = vm.addr(ownerPrivateKey);
        }
        
        console.log("Owner address:", owner);
        console.log("EntryPoint address:", config.entryPoint);
    }
    
    function run() external {
        setUp();
        
        console.log("=== Starting Complete Flow Test ===");
        
        // Step 1: Deploy AccountFactory (if not already deployed)
        address factoryAddr = deployAccountFactory();
        
        // Step 2: Create Smart Account
        address accountAddr = createSmartAccount(factoryAddr);
        
        // Step 3: Fund the account
        fundAccount(accountAddr);
        
        // Step 4: Deploy and link TaskManager
        deployTaskManager(accountAddr);
        
        // Step 5: Set penalty mechanism
        setPenaltyMechanism(accountAddr);
        
        // Step 6: Create tasks
        createTasks(accountAddr);
        
        // Step 7: Complete a task
        completeTask(accountAddr, 0);
        
        // Step 8: Let a task expire and test penalty
        testTaskExpiry(accountAddr);
        
        console.log("=== Complete Flow Test Finished ===");
    }
    
    function deployAccountFactory() internal returns (address) {
        console.log("\n--- Step 1: Deploying Account Factory ---");
        
        vm.startBroadcast(ownerPrivateKey);
        factory = new AccountFactory(config.entryPoint, owner);
        vm.stopBroadcast();
        
        console.log("AccountFactory deployed at:", address(factory));
        return address(factory);
    }
    
    function createSmartAccount(address factoryAddr) internal returns (address) {
        console.log("\n--- Step 2: Creating Smart Account ---");
        
        factory = AccountFactory(factoryAddr);
        uint256 nonce = 0;
        
        vm.startBroadcast(ownerPrivateKey);
        address accountAddr = factory.createAccount(nonce);
        vm.stopBroadcast();
        
        smartAccount = SimpleAccount(payable(accountAddr));
        console.log("Smart Account created at:", accountAddr);
        console.log("Account owner:", smartAccount.s_owner());
        
        return accountAddr;
    }
    
    function fundAccount(address accountAddr) internal {
        console.log("\n--- Step 3: Funding Account ---");
        
        vm.startBroadcast(ownerPrivateKey);
        payable(accountAddr).transfer(1 ether); // Fund with 1 ETH
        vm.stopBroadcast();
        
        console.log("Account funded with 1 ETH");
        console.log("Account balance:", address(accountAddr).balance);
    }
    
    function deployTaskManager(address accountAddr) internal {
        console.log("\n--- Step 4: Deploying TaskManager ---");
        
        smartAccount = SimpleAccount(payable(accountAddr));
        
        // Use UserOperation to deploy TaskManager
        bytes memory callData = abi.encodeWithSelector(
            SimpleAccount.deployAndLinkTaskManager.selector
        );
        
        executeUserOperation(callData, 0, "Deploy TaskManager");
        
        address taskManagerAddr = address(smartAccount.taskManager());
        console.log("TaskManager deployed and linked at:", taskManagerAddr);
    }
    
    function setPenaltyMechanism(address accountAddr) internal {
        console.log("\n--- Step 5: Setting Penalty Mechanism ---");
        
        smartAccount = SimpleAccount(payable(accountAddr));
        
        // Set delay penalty of 1 hour (3600 seconds)
        bytes memory callData = abi.encodeWithSelector(
            SimpleAccount.setDelayPenalty.selector,
            3600 // 1 hour delay
        );
        
        executeUserOperation(callData, 0, "Set Delay Penalty");
        console.log("Delay penalty set to 1 hour");
    }
    
    function createTasks(address accountAddr) internal {
        console.log("\n--- Step 6: Creating Tasks ---");
        
        smartAccount = SimpleAccount(payable(accountAddr));
        
        // Create Task 1: Short deadline (30 seconds) - will be completed
        bytes memory callData1 = abi.encodeWithSelector(
            SimpleAccount.createTask.selector,
            "Complete morning workout",
            0.1 ether,
            30 // 30 seconds deadline
        );
        
        executeUserOperation(callData1, 0, "Create Task 1");
        console.log("Task 1 created: Morning workout (30s deadline, 0.1 ETH reward)");
        
        // Create Task 2: Longer deadline (60 seconds) - will expire
        bytes memory callData2 = abi.encodeWithSelector(
            SimpleAccount.createTask.selector,
            "Read 10 pages of book",
            0.05 ether,
            60 // 60 seconds deadline
        );
        
        executeUserOperation(callData2, 0, "Create Task 2");
        console.log("Task 2 created: Read book (60s deadline, 0.05 ETH reward)");
        
        // Check total committed rewards
        console.log("Total committed rewards:", smartAccount.s_totalCommittedReward());
    }
    
    function completeTask(address accountAddr, uint256 taskId) internal {
        console.log("\n--- Step 7: Completing Task ---");
        
        smartAccount = SimpleAccount(payable(accountAddr));
        
        uint256 balanceBefore = owner.balance;
        
        bytes memory callData = abi.encodeWithSelector(
            SimpleAccount.completeTask.selector,
            taskId
        );
        
        executeUserOperation(callData, 0, "Complete Task");
        
        uint256 balanceAfter = owner.balance;
        console.log("Task", taskId, "completed!");
        console.log("Owner balance increased by:", balanceAfter - balanceBefore);
    }
    
    function testTaskExpiry(address accountAddr) internal {
        console.log("\n--- Step 8: Testing Task Expiry ---");
        
        smartAccount = SimpleAccount(payable(accountAddr));
        
        // Wait for task to expire (advance time by 65 seconds)
        vm.warp(block.timestamp + 65);
        console.log("Time advanced by 65 seconds");
        
        // Manually expire the second task
        bytes memory callData = abi.encodeWithSelector(
            smartAccount.taskManager().expireTask.selector,
            1 // Task ID 1 (second task)
        );
        
        // Call directly on TaskManager since expireTask is not owner-restricted
        vm.startBroadcast(ownerPrivateKey);
        (bool success,) = address(smartAccount.taskManager()).call(callData);
        vm.stopBroadcast();
        
        if (success) {
            console.log("Task 1 expired - penalty mechanism triggered");
        } else {
            console.log("Failed to expire task");
        }
        
        // Try to release delayed payment after delay period
        vm.warp(block.timestamp + 3601); // Wait for delay period
        
        bytes memory releaseCallData = abi.encodeWithSelector(
            SimpleAccount.releaseDelayedPayment.selector,
            1
        );
        
        executeUserOperation(releaseCallData, 0, "Release Delayed Payment");
        console.log("Delayed payment released after penalty period");
    }
    
    function executeUserOperation(bytes memory callData, uint256 value, string memory description) internal {
        console.log("Executing:", description);
        
        // Prepare the execute call
        bytes memory executeCallData = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(smartAccount),
            value,
            callData
        );
        
        // Generate and execute UserOperation
        PackedUserOperation memory userOp = generateSignedUserOperation(
            executeCallData,
            address(smartAccount)
        );
        
        vm.startBroadcast(ownerPrivateKey);
        
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        
        try IEntryPoint(config.entryPoint).handleOps(userOps, payable(owner)) {
            console.log(" UserOperation executed successfully");
        } catch Error(string memory reason) {
            console.log(" UserOperation failed:", reason);
        } catch {
            console.log(" UserOperation failed with unknown error");
        }
        
        vm.stopBroadcast();
    }
    
    function generateSignedUserOperation(
        bytes memory callData,
        address sender
    ) internal view returns (PackedUserOperation memory) {
        uint256 nonce = IEntryPoint(config.entryPoint).getNonce(sender, 0);
        PackedUserOperation memory userOp = _generateUnsignedUserOperation(callData, sender, nonce);
        
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);
        bytes32 digest = userOpHash.toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        userOp.signature = abi.encodePacked(r, s, v);
        
        return userOp;
    }
    
    function _generateUnsignedUserOperation(
        bytes memory callData,
        address sender,
        uint256 nonce
    ) internal pure returns (PackedUserOperation memory) {
        uint128 verificationGasLimit = 1e6;
        uint128 callGasLimit = 1e6;
        uint128 maxPriorityFeePerGas = 1e9;
        uint128 maxFeePerGas = 2e9;
        
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(uint256(verificationGasLimit) << 128 | callGasLimit),
            preVerificationGas: verificationGasLimit,
            gasFees: bytes32(uint256(maxPriorityFeePerGas) << 128 | maxFeePerGas),
            paymasterAndData: hex"",
            signature: hex""
        });
    }
}

/**
 * @title Simple Account Creation Script
 * @notice Basic script to create an account
 */
contract CreateAccountScript is Script {
    function run() external {
        // Get configuration
        HelperConfig configHelper = new HelperConfig();
        HelperConfig.NetworkConfig memory config = configHelper.getConfig();
        
        // Set up owner
        uint256 ownerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address owner = vm.addr(ownerPrivateKey);
        
        vm.startBroadcast(ownerPrivateKey);
        
        // Deploy factory
        AccountFactory factory = new AccountFactory(config.entryPoint, owner);
        console.log("Factory deployed at:", address(factory));
        
        // Create account
        uint256 nonce = 0;
        address account = factory.createAccount(nonce);
        console.log("Created account at:", account);
        
        // Fund the account
        payable(account).transfer(0.5 ether);
        console.log("Account funded with 0.5 ETH");
        
        vm.stopBroadcast();
    }
}

/**
 * @title Task Management Test Script
 * @notice Tests task creation, completion, and expiry
 */
contract TaskManagementTest is Script {
    using MessageHashUtils for bytes32;
    
    address constant SMART_ACCOUNT = 0x73Ff90Df627AA6d6fe997FEC4CcAE2eF736F03e3; // Update this
    uint256 constant OWNER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    
    function run() external {
        address owner = vm.addr(OWNER_PRIVATE_KEY);
        
        // Get configuration
        HelperConfig configHelper = new HelperConfig();
        HelperConfig.NetworkConfig memory config = configHelper.getConfig();
        
        SimpleAccount smartAccount = SimpleAccount(payable(SMART_ACCOUNT));
        
        // Test 1: Deploy TaskManager if not exists
        if (address(smartAccount.taskManager()) == address(0)) {
            console.log("Deploying TaskManager...");
            executeUserOp(
                abi.encodeWithSelector(SimpleAccount.deployAndLinkTaskManager.selector),
                config,
                owner,
                SMART_ACCOUNT,
                0
            );
        }
        
        // Test 2: Set penalty mechanism
        console.log("Setting delay penalty...");
        executeUserOp(
            abi.encodeWithSelector(SimpleAccount.setDelayPenalty.selector, 1800), // 30 minutes
            config,
            owner,
            SMART_ACCOUNT,
            0
        );
        
        // Test 3: Create a task
        console.log("Creating task...");
        bytes memory taskCallData = abi.encodeWithSelector(
            SimpleAccount.createTask.selector,
            "Complete daily exercise",
            0.01 ether,
            300 // 5 minutes
        );
        
        executeUserOp(taskCallData, config, owner, SMART_ACCOUNT, 0);
        
        console.log("Task created successfully!");
        console.log("Total committed rewards:", smartAccount.s_totalCommittedReward());
    }
    
    function executeUserOp(
        bytes memory functionData,
        HelperConfig.NetworkConfig memory config,
        address owner,
        address smartAccount,
        uint256 value
    ) internal {
        bytes memory callData = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            smartAccount,
            value,
            functionData
        );
        
        vm.startBroadcast(OWNER_PRIVATE_KEY);
        
        // Fund account if needed
        if (smartAccount.balance < 0.1 ether) {
            payable(smartAccount).transfer(0.1 ether);
        }
        
        PackedUserOperation memory userOp = generateSignedUserOperation(
            callData,
            config,
            OWNER_PRIVATE_KEY,
            smartAccount
        );
        
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        
        IEntryPoint(config.entryPoint).handleOps(userOps, payable(owner));
        
        vm.stopBroadcast();
    }
    
    function generateSignedUserOperation(
        bytes memory callData,
        HelperConfig.NetworkConfig memory config,
        uint256 privateKey,
        address sender
    ) internal view returns (PackedUserOperation memory) {
        uint256 nonce = IEntryPoint(config.entryPoint).getNonce(sender, 0);
        PackedUserOperation memory userOp = _generateUnsignedUserOperation(callData, sender, nonce);
        
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);
        bytes32 digest = userOpHash.toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        userOp.signature = abi.encodePacked(r, s, v);
        
        return userOp;
    }
    
    function _generateUnsignedUserOperation(
        bytes memory callData,
        address sender,
        uint256 nonce
    ) internal pure returns (PackedUserOperation memory) {
        uint128 verificationGasLimit = 1e6;
        uint128 callGasLimit = 1e6;
        uint128 maxPriorityFeePerGas = 1e9;
        uint128 maxFeePerGas = 2e9;
        
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(uint256(verificationGasLimit) << 128 | callGasLimit),
            preVerificationGas: verificationGasLimit,
            gasFees: bytes32(uint256(maxPriorityFeePerGas) << 128 | maxFeePerGas),
            paymasterAndData: hex"",
            signature: hex""
        });
    }
}