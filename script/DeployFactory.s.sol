// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/Mandate.sol";
import "../src/MandateFactory.sol";

contract DeployFactoryScript is Script {
    // Base network token addresses
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDT_BASE = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mandate implementation (template for clones)
        Mandate implementation = new Mandate();
        console.log("Mandate implementation deployed at:", address(implementation));

        // Deploy factory (this is what users will interact with)
        MandateFactory factory = new MandateFactory(address(implementation));
        console.log("MandateFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Debyth Mandate Protocol Deployed Successfully ===");
        console.log("Factory Owner:", deployer);
        console.log("Supported tokens on Base:");
        console.log("  USDC:", USDC_BASE);
        console.log("  USDT:", USDT_BASE);
        console.log("");
        console.log("=== Usage Instructions ===");
        console.log("Users can now deploy their own mandate contracts by calling:");
        console.log("factory.deployMandateContract([USDC_BASE, USDT_BASE])");
        console.log("");
        console.log("Each user gets their own isolated mandate contract instance.");
        console.log("Factory address to use in your frontend:", address(factory));
    }
}