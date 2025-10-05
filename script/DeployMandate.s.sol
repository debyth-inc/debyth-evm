// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import "../src/Mandate.sol";
import "../src/MandateFactory.sol";

contract DeployMandateScript is Script {
    // Base network token addresses
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDT_BASE = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mandate implementation
        Mandate implementation = new Mandate();

        // Deploy factory
        MandateFactory factory = new MandateFactory(address(implementation));

        // Deploy a main mandate contract for the protocol
        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = USDC_BASE;
        supportedTokens[1] = USDT_BASE;

        // Deploy main protocol clone
        address mainClone = factory.deployMandateContract(supportedTokens);

        vm.stopBroadcast();

        console.log("=== Debyth Mandate Protocol Deployment ===");
        console.log("Implementation deployed at:", address(implementation));
        console.log("Factory deployed at:", address(factory));
        console.log("Main Protocol Clone deployed at:", mainClone);
        console.log("Admin:", deployer);
        console.log("");
        console.log("Supported tokens:");
        console.log("  USDC (Base):", USDC_BASE);
        console.log("  USDT (Base):", USDT_BASE);
        console.log("");
        console.log("Next steps:");
        console.log("1. Add executors to the main contract");
        console.log("2. Users can deploy their own mandate contracts via factory");
        console.log("3. Or use the main protocol contract for shared mandates");
    }
}
