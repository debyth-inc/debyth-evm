// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MandateFactory} from "../src/MandateFactory.sol";
import {Mandate} from "../src/Mandate.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MandateFactoryTest is Test {
    MandateFactory public factory;
    Mandate public implementation;
    MockERC20 public usdc;
    MockERC20 public usdt;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether USD", "USDT");

        // Deploy implementation
        implementation = new Mandate();

        // Deploy factory
        vm.prank(owner);
        factory = new MandateFactory(address(implementation));
    }

    function testDeployMandateContract() public {
        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(usdt);

        vm.prank(user1);
        address mandateContract = factory.deployMandateContract(supportedTokens);

        // Verify deployment
        assertTrue(mandateContract != address(0));

        // Verify user contracts tracking
        address[] memory userContracts = factory.getUserMandateContracts(user1);
        assertEq(userContracts.length, 1);
        assertEq(userContracts[0], mandateContract);

        // Verify total contracts tracking
        assertEq(factory.getTotalMandateContracts(), 1);
        assertEq(factory.getMandateContractAt(0), mandateContract);

        // Verify the deployed contract is properly initialized
        Mandate mandate = Mandate(mandateContract);
        assertTrue(mandate.hasRole(mandate.DEFAULT_ADMIN_ROLE(), user1));
        assertTrue(mandate.supportedTokens(address(usdc)));
        assertTrue(mandate.supportedTokens(address(usdt)));
    }

    function testMultipleUsersDeployContracts() public {
        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        // User1 deploys contract
        vm.prank(user1);
        address contract1 = factory.deployMandateContract(supportedTokens);

        // User2 deploys contract
        vm.prank(user2);
        address contract2 = factory.deployMandateContract(supportedTokens);

        // Verify separate tracking
        address[] memory user1Contracts = factory.getUserMandateContracts(user1);
        address[] memory user2Contracts = factory.getUserMandateContracts(user2);

        assertEq(user1Contracts.length, 1);
        assertEq(user2Contracts.length, 1);
        assertEq(user1Contracts[0], contract1);
        assertEq(user2Contracts[0], contract2);

        // Verify total tracking
        assertEq(factory.getTotalMandateContracts(), 2);
    }

    function testUserCanDeployMultipleContracts() public {
        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        vm.startPrank(user1);

        // Deploy first contract
        address contract1 = factory.deployMandateContract(supportedTokens);

        // Deploy second contract
        address contract2 = factory.deployMandateContract(supportedTokens);

        vm.stopPrank();

        // Verify user has both contracts
        address[] memory userContracts = factory.getUserMandateContracts(user1);
        assertEq(userContracts.length, 2);
        assertEq(userContracts[0], contract1);
        assertEq(userContracts[1], contract2);
    }

    function testGetMandateContractAtBounds() public {
        // Test empty array
        vm.expectRevert("Index out of bounds");
        factory.getMandateContractAt(0);

        // Deploy one contract
        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        vm.prank(user1);
        factory.deployMandateContract(supportedTokens);

        // Test valid index
        address contract1 = factory.getMandateContractAt(0);
        assertTrue(contract1 != address(0));

        // Test invalid index
        vm.expectRevert("Index out of bounds");
        factory.getMandateContractAt(1);
    }

    function testFactoryEvents() public {
        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(usdt);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit MandateFactory.MandateContractDeployed(user1, address(0), supportedTokens);

        factory.deployMandateContract(supportedTokens);
    }
}
