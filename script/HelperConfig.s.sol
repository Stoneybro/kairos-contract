// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {EntryPoint} from "lib/account-abstraction/contracts/core/EntryPoint.sol";
import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    struct NetworkConfig {
        address entryPoint;
        address account;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    NetworkConfig public localNetwork;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 constant LOCAL_CHAIN_ID = 31337;
    address constant BURNER_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant SEPOLIA_WALLET = 0x0D96081998fd583334fd1757645B40fdD989B267;
    uint256 constant OWNER_PRIVATE_KEY = 1;
    address public immutable signingAccount;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error HelperConfig__UnsupportedNetwork();

    /*CONSTRUCTOR*/
    constructor() {
        signingAccount = vm.addr(OWNER_PRIVATE_KEY);
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getConfig() external returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (chainId == ETH_SEPOLIA_CHAIN_ID) {
            return getSepoliaEthConfig();
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getAnvilEthConfig();
        } else if (chainId == BASE_SEPOLIA_CHAIN_ID) {
            return getBaseSepoliaEthConfig();
        } else {
            revert HelperConfig__UnsupportedNetwork();
        }
    }

    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({entryPoint: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789, account: BURNER_WALLET});
    }

    function getBaseSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({entryPoint: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789, account: SEPOLIA_WALLET});
    }

    function getAnvilEthConfig() public returns (NetworkConfig memory) {
        // Return existing config if already deployed
        if (localNetwork.entryPoint != address(0)) {
            return localNetwork;
        }

        // Deploy new EntryPoint for local network

        EntryPoint entryPoint = new EntryPoint();

        localNetwork = NetworkConfig({entryPoint: address(entryPoint), account: signingAccount});

        return localNetwork;
    }
}
