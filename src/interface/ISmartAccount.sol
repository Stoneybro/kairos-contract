// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ISmartAccount is IERC165 {
    function expiredTaskCallback(uint256 taskId) external;
    function automatedDelayedPaymentRelease(uint256 taskId) external; // NEW: Added to interface
    function automatedBuddyPaymentAttempt(uint256 taskId) external returns (bool success); // NEW: For buddy payment attempts
}