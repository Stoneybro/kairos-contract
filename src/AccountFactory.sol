// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SmartAccount} from "./SmartAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ITaskManager} from "./interface/ITaskManager.sol";

/**
 * @title AccountFactory
 * @author Livingstone Z.
 * @notice Deterministic clone factory for SmartAccount.
 * @dev
 * - One SmartAccount clone per EOA. Salt = keccak256(abi.encodePacked(user)).
 * - Clones are initialized with a fixed EntryPoint and TaskManager.
 * - Uses OpenZeppelin Clones.cloneDeterministic for predictable addresses.
 *
 * Security notes:
 * - Factory does not implement upgradeability. Implementation address is immutable.
 * - The factory stores a single clone per user and prevents redeployment.
 */
contract AccountFactory {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice SmartAccount implementation used as clone template.
    address public immutable implementation;

    /// @notice Mapping from user EOA to deployed SmartAccount clone.
    mapping(address user => address clone) public userClones;

    /// @notice Immutable EntryPoint address used to initialize clones.
    address private immutable i_entryPoint;

    /// @notice Immutable TaskManager used to initialize clones.
    ITaskManager private immutable i_taskManager;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when a clone is created.
    event CloneCreated(address indexed clone, address indexed user, bytes32 indexed salt);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error AccountFactory__UserAlreadyHasAccount();
    error AccountFactory__InitializationFailed();
    error AccountFactory__InvalidEntryPoint();
    error AccountFactory__InvalidTaskManager();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param entryPoint EntryPoint address passed to clones.
     * @param taskManager TaskManager address passed to clones.
     */
    constructor(address entryPoint, address taskManager) {
        if (entryPoint == address(0)) revert AccountFactory__InvalidEntryPoint();
        if (taskManager == address(0)) revert AccountFactory__InvalidTaskManager();

        // Deploy implementation once and reuse for all clones. Saves gas on future deployments.
        implementation = address(new SmartAccount());
        i_entryPoint = entryPoint;
        i_taskManager = ITaskManager(taskManager);
    }

    /*//////////////////////////////////////////////////////////////
                           ACCOUNT DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a SmartAccount clone for the caller. Each caller may only deploy once.
     * @return account Address of the deployed clone.
     */
    function createAccount() external returns (address account) {
        // Disallow redeploy for the same user
        if (userClones[msg.sender] != address(0)) revert AccountFactory__UserAlreadyHasAccount();
        //prevents bad actors from pre-deploying with same salt
        bytes32 salt = keccak256(abi.encodePacked(msg.sender));

        // Defensive check: if code already at predicted address, treat as already deployed.
        address predicted = Clones.predictDeterministicAddress(implementation, salt);
        if (predicted.code.length != 0) revert AccountFactory__UserAlreadyHasAccount();

        // Deploy clone with deterministic address
        account = Clones.cloneDeterministic(implementation, salt);

        // Record mapping and emit for off-chain indexing
        userClones[msg.sender] = account;
        emit CloneCreated(account, msg.sender, salt);

        // Initialize the clone. If initialization fails, surface a clear error.
        try SmartAccount(payable(account)).initialize(msg.sender, i_entryPoint, i_taskManager) {
            // initialization succeeded
        } catch {
            revert AccountFactory__InitializationFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                               PREDICTION HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Predict the deterministic SmartAccount address for the caller.
     * @dev Uses the same salt generation as `createAccount`.
     */
    function getAddress() external view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender));
        predictedAddress = Clones.predictDeterministicAddress(implementation, salt);
    }

    /**
     * @notice Predict the deterministic SmartAccount address for an arbitrary EOA.
     * @param user EOA to compute the clone address for.
     */
    function getAddressForUser(address user) external view returns (address predictedAddress) {
        bytes32 salt = keccak256(abi.encodePacked(user));
        predictedAddress = Clones.predictDeterministicAddress(implementation, salt);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the clone address for a user or zero if none.
    function getUserClone(address user) external view returns (address) {
        return userClones[user];
    }

    /// @notice Returns the implementation template address.
    function getImplementation() external view returns (address) {
        return implementation;
    }

    /// @notice Returns the configured EntryPoint address used for initialization.
    function getEntryPoint() external view returns (address) {
        return i_entryPoint;
    }

    /// @notice Returns the configured TaskManager address used for initialization.
    function getTaskManager() external view returns (address) {
        return address(i_taskManager);
    }
}
