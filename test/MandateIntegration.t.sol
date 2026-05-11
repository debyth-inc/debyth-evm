// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Mandate} from "../src/Mandate.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MandateIntegrationTest is Test {
    Mandate public mandateContract;
    MockERC20 public usdc;

    uint256 public mandateIdCounter;

    function generateMandateId() internal returns (bytes32) {
        return keccak256(abi.encodePacked("mandate-", mandateIdCounter++));
    }

    address public sender = makeAddr("sender");
    address public recipient = makeAddr("recipient");
    address public executor = makeAddr("executor");

    uint256 constant TOTAL_LIMIT = 1000e6;
    uint256 constant PER_EXECUTION_LIMIT = 100e6;
    uint256 constant MIN_INTERVAL = 30 days;

    function computePolicyHash(
        Mandate.ChargeType chargeType,
        Mandate.Frequency frequency,
        uint256 minIntervalSeconds,
        uint256 perExecutionLimit,
        uint256 totalLimit,
        uint256 startAt,
        uint256 endAt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            chargeType, frequency, minIntervalSeconds, perExecutionLimit, totalLimit, startAt, endAt
        ));
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");

        Mandate implementation = new Mandate();

        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        bytes memory initData = abi.encodeWithSelector(Mandate.initialize.selector, sender, supportedTokens, executor);

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), sender, initData);

        mandateContract = Mandate(address(proxy));

        usdc.mint(sender, 10000e6);
        mandateIdCounter = 0;
    }

    function testFullMandateWorkflow() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.FIXED, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, startAt, endAt
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandateContract.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.FIXED, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            startAt, endAt, empty, empty, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(sender);
        mandateContract.approveMandate(mandateId);

        uint256 paymentAmount = PER_EXECUTION_LIMIT;
        uint256 senderBalanceBefore = usdc.balanceOf(sender);
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.prank(executor);
        mandateContract.executeMandate(mandateId, paymentAmount, 1);

        assertEq(usdc.balanceOf(sender), senderBalanceBefore - paymentAmount);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + paymentAmount);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_ExecutionTooEarly.selector);
        mandateContract.executeMandate(mandateId, paymentAmount, 2);

        vm.warp(block.timestamp + MIN_INTERVAL);

        vm.prank(executor);
        mandateContract.executeMandate(mandateId, paymentAmount, 2);

        Mandate.MandateData memory m = mandateContract.getMandate(mandateId);
        assertEq(m.totalExecuted, paymentAmount * 2);

        vm.prank(sender);
        mandateContract.cancelMandate(mandateId);

        vm.warp(block.timestamp + MIN_INTERVAL);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandateContract.executeMandate(mandateId, paymentAmount, 3);
    }

    function testMandateWithInsufficientAllowance() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, startAt, endAt
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandateContract.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            startAt, endAt, empty, empty, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(sender);
        mandateContract.approveMandate(mandateId);

        vm.prank(sender);
        usdc.approve(address(mandateContract), 10e6);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandateContract.executeMandate(mandateId, 50e6, 1);
    }

    function testMandateExpiration() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 1 days;

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, startAt, endAt
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandateContract.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            startAt, endAt, empty, empty, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(sender);
        mandateContract.approveMandate(mandateId);

        vm.warp(endAt + 1 days);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateExpired.selector);
        mandateContract.executeMandate(mandateId, 50e6, 1);
    }

    function testUserRevokeAllowance() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, startAt, endAt
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandateContract.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            startAt, endAt, empty, empty, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(sender);
        mandateContract.approveMandate(mandateId);

        vm.prank(sender);
        usdc.approve(address(mandateContract), 0);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandateContract.executeMandate(mandateId, 50e6, 1);
    }

    function testMandateWithAllowedRecipients() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, startAt, endAt
        );

        address[] memory allowedRecipients = new address[](1);
        allowedRecipients[0] = recipient;

        address[] memory emptyAssets;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandateContract.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            startAt, endAt, allowedRecipients, emptyAssets, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(sender);
        mandateContract.approveMandate(mandateId);

        vm.prank(executor);
        mandateContract.executeMandate(mandateId, 50e6, 1);
    }

    function testMandateWithPolicyHashMismatch() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 realPolicyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, startAt, endAt
        );

        bytes32 wrongPolicyHash = keccak256("wrong");

        address[] memory empty;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandateContract.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            startAt, endAt, empty, empty, wrongPolicyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(sender);
        mandateContract.approveMandate(mandateId);

        vm.prank(executor);
        mandateContract.executeMandate(mandateId, 50e6, 1);
    }
}
