// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Mandate} from "../src/Mandate.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MandateTest is Test {
    Mandate public mandate;
    MockERC20 public usdc;
    MockERC20 public usdt;

    uint256 public mandateIdCounter;

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public sender = makeAddr("sender");
    address public recipient = makeAddr("recipient");

    uint256 constant TOTAL_LIMIT = 1000e6;
    uint256 constant PER_EXECUTION_LIMIT = 100e6;
    uint256 constant MIN_INTERVAL = 30 days;

    event MandateCreated(
        bytes32 indexed mandateId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 totalLimit,
        uint256 perExecutionLimit,
        bytes32 policyHash,
        uint256 startAt,
        uint256 endAt
    );

    event MandateExecuted(
        bytes32 indexed mandateId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 totalCharged,
        uint256 timestamp,
        uint64 nonce,
        bytes32 policyHash
    );

    function generateMandateId() internal returns (bytes32) {
        return keccak256(abi.encodePacked("mandate-", mandateIdCounter++));
    }

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
        usdt = new MockERC20("Tether USD", "USDT");

        Mandate implementation = new Mandate();

        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(usdt);

        vm.prank(admin);
        bytes memory initData = abi.encodeWithSelector(Mandate.initialize.selector, admin, supportedTokens, executor);

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, initData);

        mandate = Mandate(address(proxy));

        usdc.mint(sender, 10000e6);
        usdt.mint(sender, 10000e6);
        mandateIdCounter = 1;
    }

    function _createMandate(
        bytes32 mandateId,
        uint256 startAt,
        uint256 endAt
    ) internal returns (bytes32) {
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            TOTAL_LIMIT,
            startAt,
            endAt
        );
        vm.prank(executor);
        return mandate.createMandate(
            sender,
            mandateId,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            startAt,
            endAt,
            empty,
            empty,
            policyHash
        );
    }

    function testCreateMandate() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 mandateId = generateMandateId();
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            TOTAL_LIMIT,
            startAt,
            endAt
        );

        address[] memory empty;

        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit MandateCreated(
            mandateId,
            sender,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            policyHash,
            startAt,
            endAt
        );

        bytes32 returnedId = mandate.createMandate(
            sender,
            mandateId,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            startAt,
            endAt,
            empty,
            empty,
            policyHash
        );
        assertEq(returnedId, mandateId);

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.sender, sender);
        assertEq(m.recipient, recipient);
        assertEq(m.token, address(usdc));
        assertEq(m.totalLimit, TOTAL_LIMIT);
        assertEq(m.perExecutionLimit, PER_EXECUTION_LIMIT);
        assertEq(m.policyHash, policyHash);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.ACTIVE));
    }

    function testExecuteMandate() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, startAt, endAt);

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        uint256 amount = 50e6;
        uint64 nonce = 1;
        bytes32 expectedPolicyHash = mandate.getMandate(mandateId).policyHash;
        uint256 senderBalanceBefore = usdc.balanceOf(sender);
        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit MandateExecuted(mandateId, sender, recipient, address(usdc), amount, amount, block.timestamp, nonce, expectedPolicyHash);

        mandate.executeMandate(mandateId, amount, nonce);

        assertEq(usdc.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + amount);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalExecuted, amount);
        assertEq(m.lastExecutionTime, block.timestamp);
        assertEq(m.lastExecutionNonce, nonce);
    }

    function testCannotExecutePaymentTooEarly() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 mandateId = generateMandateId();
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.FIXED,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            TOTAL_LIMIT,
            startAt,
            endAt
        );

        vm.prank(executor);
        mandate.createMandate(
            sender,
            mandateId,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.FIXED,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            startAt,
            endAt,
            empty,
            empty,
            policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 1);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_ExecutionTooEarly.selector);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 2);

        vm.warp(block.timestamp + MIN_INTERVAL);
        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 3);
    }

    function testCancelMandate() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, startAt, endAt);

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.CANCELLED));

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testCanExecutePayment() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, startAt, endAt);

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        (bool canExecute, string memory reason) = mandate.canExecuteMandate(mandateId, 50e6, 1);
        assertTrue(canExecute);
        assertEq(reason, "");

        vm.prank(sender);
        usdc.approve(address(mandate), 0);

        (canExecute, reason) = mandate.canExecuteMandate(mandateId, 50e6, 1);
        assertFalse(canExecute);
        assertEq(reason, "Insufficient allowance");
    }

    function testPauseUnpause() public {
        vm.prank(admin);
        mandate.pauseContract();

        bytes32 mandateId = generateMandateId();
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            TOTAL_LIMIT,
            block.timestamp,
            block.timestamp + 365 days
        );

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.createMandate(
            sender,
            mandateId,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            block.timestamp,
            block.timestamp + 365 days,
            empty,
            empty,
            policyHash
        );

        vm.prank(admin);
        mandate.unpauseContract();

        bytes32 mandateId2 = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender,
            mandateId2,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            block.timestamp,
            block.timestamp + 365 days,
            empty,
            empty,
            policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId2);
    }

    function testExecutionPaused() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, startAt, endAt);

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.prank(admin);
        mandate.pauseExecution();

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_ExecutionPaused.selector);
        mandate.executeMandate(mandateId, 50e6, 1);

        vm.prank(admin);
        mandate.resumeExecution();

        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 1);
    }
}
