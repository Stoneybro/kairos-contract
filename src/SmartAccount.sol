// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UserOperation} from "@account-abstraction/contracts/interfaces/UserOperation.sol";
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ITaskManager} from "./interface/ITaskManager.sol";
import {ISmartAccount} from "./interface/ISmartAccount.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SmartAccount
 * @author Livingstone Z.
 * @notice Account-abstraction compatible smart account used by the KAIROS accountability wallet.
 * @dev
 * - Integrates with an EntryPoint (ERC-4337) and a TaskManager for task lifecycle management.
 * - Tracks committed rewards to prevent draining funds reserved for tasks.
 * - Uses a simple nonce for replay protection.
 * - Exposes EIP-1271 style `isValidSignature` for on-chain/off-chain signature verification.
 *
 * Security notes:
 * - ReentrancyGuard protects public functions that perform external calls and state changes.
 * - `s_totalCommittedReward` must always be <= contract balance. TaskManager must honor invariants.
 */
contract SmartAccount is Initializable, IAccount, ISmartAccount, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Account owner address. Signer of UserOperations.
    address public s_owner;

    /// @notice EntryPoint contract used for account abstraction.
    IEntryPoint public i_entryPoint;

    /// @notice External TaskManager that stores tasks and their lifecycle.
    ITaskManager public taskManager;

    /// @notice Sum of all rewards that are currently committed to tasks.
    /// @dev These funds must remain locked and not withdrawable by the account.
    uint256 public s_totalCommittedReward;

    /// @notice Penalty type: delayed payment.
    uint8 public constant PENALTY_DELAYEDPAYMENT = 1;

    /// @notice Penalty type: transfer to buddy.
    uint8 public constant PENALTY_SENDBUDDY = 2;

    /// @notice EIP-1271 magic return value for valid signatures.
    bytes4 internal constant _EIP1271_MAGICVALUE = 0x1626ba7e;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Initialized(address indexed owner, address indexed entryPoint, address taskManager);
    event TaskCreated(uint256 indexed taskId, string description, uint256 rewardAmount);
    event TaskCompleted(uint256 indexed taskId);
    event TaskCanceled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);
    event DurationPenaltyApplied(uint256 indexed taskId, uint256 indexed penaltyDuration);
    event DelayedPaymentReleased(uint256 indexed taskId, uint256 indexed rewardAmount);
    event PenaltyFundsReleasedToBuddy(uint256 indexed taskId, uint256 indexed rewardAmount, address indexed buddy);
    event NonceChanged(uint256 indexed nonce);
    event DepositAdded(address indexed sender, uint256 amount);
    event DepositWithdrawn(address indexed withdrawAddress, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error SmartAccount__NotFromEntryPoint();
    error SmartAccount__ExecutionFailed(bytes result);
    error SmartAccount__AddMoreFunds();
    error SmartAccount__TaskRewardPaymentFailed();
    error SmartAccount__OnlyTaskManagerCanCall();
    error SmartAccount__PenaltyDurationNotElapsed();
    error SmartAccount__PenaltyTypeMismatch();
    error SmartAccount__PayPrefundFailed();
    error SmartAccount__PickAPenalty();
    error SmartAccount__InvalidPenaltyChoice();
    error SmartAccount__NoTaskManagerLinked();
    error SmartAccount__CannotWithdrawCommittedRewards();
    error SmartAccount__TaskNotExpired();
    error SmartAccount__PaymentAlreadyReleased();
    error SmartAccount__TaskAlreadyCompleted();
    error SmartAccount__TaskAlreadyCanceled();
    error SmartAccount__InvalidPenaltyConfig();
    error SmartAccount__RewardCannotBeZero();
    error SmartAccount__InvalidNonce();
    error SmartAccount__InvalidVerificationMethod();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Allow only EntryPoint to call. EntryPoint has validated the UserOperation using `validateUserOp`.
     */
    modifier requireFromEntryPoint() {
        if (msg.sender != address(i_entryPoint)) revert SmartAccount__NotFromEntryPoint();
        _;
    }

    /**
     * @dev Ensure contract has enough free balance to cover additional task reward.
     * Reverts if caller tries to commit more than available non-committed balance.
     */
    modifier contractFundedForTasks(uint256 rewardAmount) {
        if (address(this).balance < s_totalCommittedReward + rewardAmount) revert SmartAccount__AddMoreFunds();
        _;
    }

    /**
     * @dev Ensure TaskManager has been linked.
     */
    modifier taskManagerLinked() {
        if (address(taskManager) == address(0)) revert SmartAccount__NoTaskManagerLinked();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACKS
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
    fallback() external payable {}

    /*//////////////////////////////////////////////////////////////
                                INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the smart account.
     * @param owner Address that will sign UserOperations for this account.
     * @param entryPoint Address of the EntryPoint contract.
     * @param _taskManager Address of the TaskManager used by this account.
     */
    function initialize(address owner, address entryPoint, ITaskManager _taskManager) external initializer {
        s_owner = owner;
        i_entryPoint = IEntryPoint(entryPoint);
        taskManager = _taskManager;

        emit Initialized(owner, entryPoint, address(_taskManager));
    }

    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a transaction from this account. Called by EntryPoint after UserOp validation.
     * @dev Ensures committed task rewards remain locked and cannot be withdrawn.
     * @param dest Destination address.
     * @param value ETH value to send.
     * @param functionData Calldata for the call.
     */
    function execute(address dest, uint256 value, bytes calldata functionData)
        external
        requireFromEntryPoint
        nonReentrant
    {
        // Prevent draining funds reserved for tasks
        if (value > (address(this).balance - s_totalCommittedReward)) {
            revert SmartAccount__CannotWithdrawCommittedRewards();
        }

        (bool success, bytes memory result) = dest.call{value: value}(functionData);
        if (!success) revert SmartAccount__ExecutionFailed(result);
    }

    /*//////////////////////////////////////////////////////////////
                           USEROP VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice EntryPoint calls this to validate a UserOperation.
     * @dev This implementation recovers signer from the `userOpHash`.
     * @param userOp UserOperation provided by EntryPoint.
     * @param userOpHash Hash calculated by EntryPoint for this UserOperation.
     * @param missingAccountFunds Amount EntryPoint asks this account to prefund for execution.
     * @return validationData Packed validation data using `_packValidationData` helper.
     */
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        requireFromEntryPoint
        returns (uint256 validationData)
    {
        validationData = _validateSignature(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    /**
     * @dev Validate the UserOperation signature.
     * Uses EIP-712 typed data signing with domain separator per EIP-4337.
     * @param userOp UserOperation provided by EntryPoint.
     * @param userOpHash Hash calculated by EntryPoint for this UserOperation.
     */
    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash)
        internal
        returns (uint256 validationData)
    {
        // build struct hash: keccak256("UserOperation(bytes32 userOpHash)")
        bytes32 TYPE_HASH = keccak256("UserOperation(bytes32 userOpHash)");
        bytes32 structHash = keccak256(abi.encode(TYPE_HASH, userOpHash));

        // domain separator per EIP-712:
        // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        bytes32 DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes("EntryPoint"));
        bytes32 versionHash = keccak256(bytes("0.6")); // match your EntryPoint version
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, nameHash, versionHash, block.chainid, address(i_entryPoint)));

        // EIP-712 digest
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // recover with tryRecover to avoid revert on malformed sig
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, userOp.signature);
        if (err != ECDSA.RecoverError.NoError) {
            // malformed or empty signature -> signature failure
            return _packValidationData(true, 0, 0);
        }

        if (signer != s_owner) {
            // signature does not match owner
            return _packValidationData(true, 0, 0);
        }

        // signature ok
        return _packValidationData(false, 0, 0);
    }

    /**
     * @dev If EntryPoint requests prefund, forward ETH to EntryPoint.
     */
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(address(i_entryPoint)).call{value: missingAccountFunds}("");
            if (!success) revert SmartAccount__PayPrefundFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                              TASK OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new task for this account.
     * @dev Caller must be EntryPoint. The caller's UserOp must be signed by `s_owner`.
     * @param description Short task description.
     * @param rewardAmount Reward in wei reserved for the task.
     * @param deadlineInSeconds Unix timestamp deadline.
     * @param choice Penalty type. Must be `1` (delayed) or `2` (send to buddy).
     * @param buddy Buddy address for PENALTY_SENDBUDDY.
     * @param delayDuration Duration in seconds for delayed payments.
     */
    function createTask(
        string calldata description,
        uint256 rewardAmount,
        uint256 deadlineInSeconds,
        uint8 choice,
        uint256 delayDuration,
        address buddy,
        uint8 verificationMethod
    ) external requireFromEntryPoint taskManagerLinked contractFundedForTasks(rewardAmount) {
        if (choice == 0) revert SmartAccount__PickAPenalty();
        if (choice > 2) revert SmartAccount__InvalidPenaltyChoice();
        if (choice == PENALTY_SENDBUDDY && buddy == address(0)) revert SmartAccount__InvalidPenaltyConfig();
        if (choice == PENALTY_DELAYEDPAYMENT && delayDuration == 0) revert SmartAccount__InvalidPenaltyConfig();
        if (rewardAmount == 0) revert SmartAccount__RewardCannotBeZero();
        if (verificationMethod > 2) revert SmartAccount__InvalidVerificationMethod();
        uint256 taskId = taskManager.createTask(
            description, rewardAmount, deadlineInSeconds, choice, delayDuration, buddy, verificationMethod
        );

        // Reserve reward funds
        s_totalCommittedReward += rewardAmount;
        emit TaskCreated(taskId, description, rewardAmount);
    }

    /**
     * @notice Mark an existing task as completed and pay the owner the reward.
     * @param taskId Task identifier returned by TaskManager when created.
     */
    function completeTask(uint256 taskId) external requireFromEntryPoint taskManagerLinked nonReentrant {
        ITaskManager.Task memory task = taskManager.getTask(address(this), taskId);

        if (task.status == ITaskManager.TaskStatus.COMPLETED) revert SmartAccount__TaskAlreadyCompleted();
        if (task.status == ITaskManager.TaskStatus.CANCELED) revert SmartAccount__TaskAlreadyCanceled();

        taskManager.completeTask(taskId);

        if (task.rewardAmount > 0) {
            s_totalCommittedReward -= task.rewardAmount;
            //remove this to let the funds go back to available balance
            (bool success,) = payable(s_owner).call{value: task.rewardAmount}("");
            if (!success) revert SmartAccount__TaskRewardPaymentFailed();
        }

        emit TaskCompleted(taskId);
    }

    /**
     *
     * @notice This is for a future implementation of attestation validation of Partner and AI verification.
     * A offchain verification method will be used for now
     */
    function completeTaskWithAttestation(uint256 taskId)
        external
        requireFromEntryPoint
        taskManagerLinked
        nonReentrant
    {
        // ITaskManager.Task memory task = taskManager.getTask(address(this), taskId);

        // if (task.status == ITaskManager.TaskStatus.COMPLETED) revert SmartAccount__TaskAlreadyCompleted();
        // if (task.status == ITaskManager.TaskStatus.CANCELED) revert SmartAccount__TaskAlreadyCanceled();

        // taskManager.completeTask(taskId);

        // if (task.rewardAmount > 0) {
        //     s_totalCommittedReward -= task.rewardAmount;

        //     (bool success,) = payable(s_owner).call{value: task.rewardAmount}("");
        //     if (!success) revert SmartAccount__TaskRewardPaymentFailed();
        // }

        // emit TaskCompleted(taskId);
    }

    /**
     * @notice Cancel a task and release the reserved reward back to free balance.
     * @param taskId Task identifier.
     */
    function cancelTask(uint256 taskId) external requireFromEntryPoint taskManagerLinked nonReentrant {
        ITaskManager.Task memory task = taskManager.getTask(address(this), taskId);
        if (task.status == ITaskManager.TaskStatus.CANCELED) revert SmartAccount__TaskAlreadyCanceled();

        taskManager.cancelTask(taskId);
        s_totalCommittedReward -= task.rewardAmount;

        emit TaskCanceled(taskId);
    }

    /**
     * @notice Release delayed payment after penalty duration elapses.
     * @param taskId Task identifier.
     */
    function releaseDelayedPayment(uint256 taskId) external requireFromEntryPoint taskManagerLinked nonReentrant {
        ITaskManager.Task memory task = taskManager.getTask(address(this), taskId);

        if (task.choice != PENALTY_DELAYEDPAYMENT) revert SmartAccount__PenaltyTypeMismatch();
        if (task.status != ITaskManager.TaskStatus.EXPIRED) revert SmartAccount__TaskNotExpired();
        if (block.timestamp <= task.deadline + task.delayDuration) revert SmartAccount__PenaltyDurationNotElapsed();
        if (task.delayedRewardReleased) revert SmartAccount__PaymentAlreadyReleased();

        taskManager.releaseDelayedPayment(taskId);
        s_totalCommittedReward -= task.rewardAmount;

        (bool success,) = payable(s_owner).call{value: task.rewardAmount}("");
        if (!success) revert SmartAccount__TaskRewardPaymentFailed();

        emit DelayedPaymentReleased(taskId, task.rewardAmount);
    }

    /*//////////////////////////////////////////////////////////////
                              TASK GETTERS
    //////////////////////////////////////////////////////////////*/

    function getTask(uint256 taskId) external view taskManagerLinked returns (ITaskManager.Task memory) {
        return taskManager.getTask(address(this), taskId);
    }

    function getTotalTasks() external view taskManagerLinked returns (uint256) {
        return taskManager.getTotalTasks(address(this));
    }

    function getTasksByStatus(ITaskManager.TaskStatus status, uint256 start, uint256 limit)
        external
        view
        taskManagerLinked
        returns (ITaskManager.Task[] memory)
    {
        return taskManager.getTasksByStatus(address(this), status, start, limit);
    }

    function getTaskCountsByStatus() external view taskManagerLinked returns (uint256[] memory) {
        return taskManager.getTaskCountsByStatus(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by TaskManager when a task expires to apply penalty logic.
     * @dev Only callable by the configured TaskManager.
     */
    function expiredTaskCallback(uint256 taskId) external override nonReentrant {
        if (msg.sender != address(taskManager)) revert SmartAccount__OnlyTaskManagerCanCall();

        ITaskManager.Task memory task = taskManager.getTask(address(this), taskId);
        if (task.status != ITaskManager.TaskStatus.EXPIRED) revert SmartAccount__TaskNotExpired();

        if (task.choice == PENALTY_DELAYEDPAYMENT) {
            // Emit when a delayed penalty starts. Actual release requires `releaseDelayedPayment` after the delay.
            emit DurationPenaltyApplied(taskId, task.deadline + task.delayDuration);
        } else if (task.choice == PENALTY_SENDBUDDY) {
            if (task.buddy == address(0)) revert SmartAccount__PickAPenalty();

            s_totalCommittedReward -= task.rewardAmount;
            (bool success,) = payable(task.buddy).call{value: task.rewardAmount}("");
            if (!success) revert SmartAccount__TaskRewardPaymentFailed();

            emit PenaltyFundsReleasedToBuddy(taskId, task.rewardAmount, task.buddy);
        } else {
            revert SmartAccount__InvalidPenaltyChoice();
        }

        emit TaskExpired(taskId);
    }

    /*//////////////////////////////////////////////////////////////
                          ENTRYPOINT DEPOSIT HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add ETH deposit for EntryPoint sponsorship.
     * @dev For compatibility with EntryPoint tooling and Paymaster flows.
     */
    function addDeposit() external payable {
        i_entryPoint.depositTo{value: msg.value}(address(this));
        emit DepositAdded(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH from EntryPoint deposit to `withdrawAddress`.
     * @dev Callable via EntryPoint so owner signs a UserOp authorizing the withdrawal.
     */
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) external requireFromEntryPoint {
        i_entryPoint.withdrawTo(withdrawAddress, amount);
        emit DepositWithdrawn(withdrawAddress, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           EIP-1271 SUPPORT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice On-chain signature verification for contracts and off-chain tooling.
     * @dev Supports both EIP-191 (`eth_sign`) and EIP-712 signatures.
     *      Returns the EIP-1271 magic value if the signature is valid.
     * @param hash Hash that was signed.
     * @param signature Signature bytes.
     * @return magicValue _EIP1271_MAGICVALUE on success, 0x0 on failure.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        // Try EIP-191 (`eth_sign`) prefix
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), signature) == s_owner) {
            return _EIP1271_MAGICVALUE;
        }
        // Try EIP-712 (assume `hash` is already typed-data digest)
        if (ECDSA.recover(hash, signature) == s_owner) {
            return _EIP1271_MAGICVALUE;
        }
        return 0xffffffff; // invalid
    }

    /**
     * @notice Interface support declaration.
     */
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ISmartAccount).interfaceId;
    }
}
