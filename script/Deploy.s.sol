// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Mandate} from "../src/Mandate.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title Universal Deploy Script
 * @notice Auto-detects chain and deploys appropriately
 * 
 * Usage:
 *   # Local (Anvil)
 *   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --private-key $PRIVATE_KEY --broadcast
 *   
 *   # Sepolia
 *   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
 *   
 *   # Mainnet
 *   forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployScript is Script {
    // Chain IDs
    uint256 constant ANVIL_CHAIN_ID = 31337;
    uint256 constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    
    // Base Mainnet tokens
    address constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_MAINNET_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    
    // Base Sepolia tokens
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory networkName;
        address[] memory supportedTokens;

        vm.startBroadcast(deployerPrivateKey);

        // ============ ANVIL / LOCAL ============
        if (block.chainid == ANVIL_CHAIN_ID) {
            networkName = "Local (Anvil)";
            
            // Deploy mock tokens
            MockERC20 mockUsdc = new MockERC20("Mock USDC", "USDC", 6);
            MockERC20 mockUsdt = new MockERC20("Mock USDT", "USDT", 6);
            
            // Mint to deployer for testing
            mockUsdc.mint(deployer, 1_000_000 * 10 ** 6);
            mockUsdt.mint(deployer, 1_000_000 * 10 ** 6);
            
            supportedTokens = new address[](2);
            supportedTokens[0] = address(mockUsdc);
            supportedTokens[1] = address(mockUsdt);
            
            console.log("Mock USDC deployed at:", address(mockUsdc));
            console.log("Mock USDT deployed at:", address(mockUsdt));
        }
        // ============ BASE SEPOLIA ============
        else if (block.chainid == BASE_SEPOLIA_CHAIN_ID) {
            networkName = "Base Sepolia";
            
            supportedTokens = new address[](1);
            supportedTokens[0] = BASE_SEPOLIA_USDC;
        }
        // ============ BASE MAINNET ============
        else if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            networkName = "Base Mainnet";
            
            supportedTokens = new address[](2);
            supportedTokens[0] = BASE_MAINNET_USDC;
            supportedTokens[1] = BASE_MAINNET_USDT;
        }
        // ============ UNSUPPORTED ============
        else {
            revert("Unsupported chain");
        }

        console.log("");
        console.log("========================================");
        console.log("  Deploying Debyth Mandate Contract");
        console.log("========================================");
        console.log("Network:", networkName);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);

        // Deploy implementation
        Mandate implementation = new Mandate();
        console.log("Implementation:", address(implementation));

        // Prepare initialization
        bytes memory initData = abi.encodeWithSelector(
            Mandate.initialize.selector,
            deployer,
            supportedTokens
        );

        // Deploy proxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            deployer,
            initData
        );

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log("  Deployment Complete!");
        console.log("========================================");
        console.log("Proxy (use this):", address(proxy));
        console.log("");
        console.log("Supported tokens:");
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            console.log("  -", supportedTokens[i]);
        }
    }
}
