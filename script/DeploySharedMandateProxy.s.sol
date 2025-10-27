// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Mandate} from "../src/Mandate.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeploySharedMandateProxyScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy mock ERC20 tokens for testing
        MockERC20 mockUsdc = new MockERC20("Mock USDC", "USDC", 6);
        MockERC20 mockUsdt = new MockERC20("Mock USDT", "USDT", 6);

        console.log("Mock USDC deployed at:", address(mockUsdc));
        console.log("Mock USDT deployed at:", address(mockUsdt));

        // Mint some tokens to deployer for testing
        mockUsdc.mint(deployer, 1_000_000 * 10 ** 6); // 1M USDC
        mockUsdt.mint(deployer, 1_000_000 * 10 ** 6); // 1M USDT

        // 2. Deploy the Mandate implementation contract
        Mandate implementation = new Mandate();
        console.log("Mandate implementation deployed at:", address(implementation));

        // 3. Prepare initialization data
        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = address(mockUsdc);
        supportedTokens[1] = address(mockUsdt);

        bytes memory initData = abi.encodeWithSelector(
            Mandate.initialize.selector,
            deployer, // admin
            supportedTokens
        );

        // 4. Deploy the proxy with initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            deployer, // proxy admin
            initData
        );

        console.log("Mandate proxy deployed at:", address(proxy));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Debyth Platform Mandate Contract Deployed Successfully ===");
        console.log("Proxy Address (use this!):", address(proxy));
        console.log("Implementation Address:", address(implementation));
        console.log("Admin/Owner:", deployer);
        console.log("");
        console.log("=== Mock Tokens Deployed ===");
        console.log("Mock USDC:", address(mockUsdc));
        console.log("Mock USDT:", address(mockUsdt));
        console.log("Deployer balance: 1,000,000 USDC and 1,000,000 USDT");
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Add executor addresses:");
        console.log(
            "   cast send",
            address(proxy),
            "\"addExecutor(address)\" <executor_address> --rpc-url http://127.0.0.1:8545 --private-key $PRIVATE_KEY"
        );
        console.log("");
        console.log("2. Mint tokens to test users:");
        console.log(
            "   cast send",
            address(mockUsdc),
            "\"mint(address,uint256)\" <user_address> 10000000000 --rpc-url http://127.0.0.1:8545 --private-key $PRIVATE_KEY"
        );
        console.log("");
        console.log("3. Businesses create mandates for users via createMandateForUser()");
        console.log("4. Users approve mandates via approveMandate()");
        console.log("5. Executors process payments via executeMandate()");
    }
}
