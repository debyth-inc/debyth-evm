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

contract MandateEdgeCasesTest is Test {
    Mandate public mandate;
    MockERC20 public usdc;

    uint256 public mandateIdCounter;

    function generateMandateId() internal returns (bytes32) {
        return keccak256(abi.encodePacked("mandate-", mandateIdCounter++));
    }

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public sender = makeAddr("sender");
    address public recipient = makeAddr("recipient");

    uint256 constant AUTHORIZED_LIMIT = 1000e6;
    uint256 constant PER_EXECUTION_LIMIT = 100e6;
    uint256 constant MIN_INTERVAL = 30 days;

    function computePolicyHash(
        Mandate.Frequency frequency,
        uint256 minIntervalSeconds,
        uint256 perExecutionLimit,
        uint256 periodLimit,
        uint256 periodWindow
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            frequency, minIntervalSeconds, perExecutionLimit, periodLimit, periodWindow
        ));
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");

        Mandate implementation = new Mandate();

        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        vm.prank(admin);
        bytes memory initData = abi.encodeWithSelector(Mandate.initialize.selector, admin, supportedTokens, executor);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, initData);
        mandate = Mandate(address(proxy));

        usdc.mint(sender, 10000e6);
        mandateIdCounter = 0;
    }

    function _createVariableMandate(
        bytes32 mandateId,
        uint256 startAt,
        uint256 endAt
    ) internal {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            startAt, endAt,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function _createFixedMandate(
        bytes32 mandateId,
        uint256 startAt,
        uint256 endAt
    ) internal {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.FIXED,
            startAt, endAt,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function _approveMandate(bytes32 mandateId) internal {
        vm.prank(sender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);
    }

    // ============ Timing Edge Cases ============

    function testExecutePaymentExactlyAtStartTime() public {
        uint256 startAt = block.timestamp + 10;

        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, startAt, startAt + 365 days);

        vm.prank(sender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.expectRevert(Mandate.Mandate_ExecutionTooEarly.selector);
        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 1);

        vm.warp(startAt);
        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testExecutePaymentExactlyAtEndTime() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 1 days;

        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, startAt, endAt);
        _approveMandate(mandateId);

        vm.warp(endAt);
        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testCannotExecutePaymentAfterEndTime() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 1 days;

        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, startAt, endAt);
        _approveMandate(mandateId);

        vm.warp(endAt + 1 days);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateExpired.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    // ============ Limit Edge Cases ============

    function testExecutePaymentHittingExactTotalLimit() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        uint256 remaining = AUTHORIZED_LIMIT;
        uint64 nonce = 1;
        while (remaining > 0) {
            uint256 amount = remaining >= PER_EXECUTION_LIMIT ? PER_EXECUTION_LIMIT : remaining;
            vm.prank(executor);
            mandate.executeMandate(mandateId, amount, nonce++);
            remaining -= amount;

            if (remaining > 0) {
                vm.warp(block.timestamp + MIN_INTERVAL);
            }
        }

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.executionState.totalExecuted, AUTHORIZED_LIMIT);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.COMPLETE));

        vm.warp(block.timestamp + MIN_INTERVAL);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executeMandate(mandateId, 1, nonce);
    }

    function testInsufficientBalanceRevert() public {
        address poorSender = makeAddr("poorSender");
        usdc.mint(poorSender, 10e6);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            poorSender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(poorSender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(poorSender);
        mandate.approveMandate(mandateId);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientBalance.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testInsufficientAllowanceRevert() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(sender);
        usdc.approve(address(mandate), 10e6);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    // ============ View Function Edge Cases ============

    function testCanExecutePaymentWithInvalidMandateId() public view {
        (bool canExecute, string memory reason) = mandate.canExecuteMandate(bytes32(uint256(999)), 50e6, 1);
        assertFalse(canExecute);
        assertEq(reason, "Invalid mandate ID");
    }

    function testCanExecutePaymentOnCanceledMandate() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        (bool canExecute, string memory reason) = mandate.canExecuteMandate(mandateId, 50e6, 1);
        assertFalse(canExecute);
        assertEq(reason, "Mandate not active");
    }

    function testCanExecutePaymentOnExpiredMandate() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 1 days;

        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, startAt, endAt);
        _approveMandate(mandateId);

        vm.warp(endAt + 1);

        (bool canExecute, string memory reason) = mandate.canExecuteMandate(mandateId, 50e6, 1);
        assertFalse(canExecute);
        assertEq(reason, "Mandate expired");
    }

    function testCanExecutePaymentForFixedDebit() public {
        bytes32 mandateId = generateMandateId();
        _createFixedMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        (bool canExecute, string memory reason) = mandate.canExecuteMandate(mandateId, 50e6, 1);
        assertFalse(canExecute);
        assertEq(reason, "Fixed debit requires exact amount");

        (canExecute, reason) = mandate.canExecuteMandate(mandateId, PER_EXECUTION_LIMIT, 1);
        assertTrue(canExecute);
        assertEq(reason, "");
    }

    function testCanExecutePaymentForVariableDebit() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        (bool canExecute, string memory reason) = mandate.canExecuteMandate(mandateId, 0, 1);
        assertFalse(canExecute);
        assertEq(reason, "Variable debit amount invalid");

        (canExecute, reason) = mandate.canExecuteMandate(mandateId, PER_EXECUTION_LIMIT + 1, 1);
        assertFalse(canExecute);
        assertEq(reason, "Variable debit amount invalid");

        (canExecute, reason) = mandate.canExecuteMandate(mandateId, 50e6, 1);
        assertTrue(canExecute);
        assertEq(reason, "");
    }

    // ============ Multiple Executors Test ============

    function testMultipleExecutorsCanExecutePayments() public {
        address executor2 = makeAddr("executor2");

        vm.prank(admin);
        mandate.addExecutor(executor2);

        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 1);

        vm.warp(block.timestamp + MIN_INTERVAL);
        vm.prank(executor2);
        mandate.executeMandate(mandateId, 50e6, 2);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.executionState.totalExecuted, 100e6);
    }

    // ============ Integer Boundary Tests ============

    function testUnlimitedSpendWithLargePayments() public {
        uint256 largeAmount = 1000000e6;

        usdc.mint(sender, largeAmount * 10);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            largeAmount, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            0, // authorizedLimit = 0 means unlimited
            Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, largeAmount,
            0, 0, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), type(uint256).max);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, largeAmount, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.executionState.totalExecuted, largeAmount);
    }

    // ============ Various Charge Types ============

    function testVariableMandateMultipleExecutions() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.DAILY, 1,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.DAILY, 1, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
        _approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, 30e6, 1);

        vm.warp(3);
        vm.prank(executor);
        mandate.executeMandate(mandateId, 20e6, 2);

        vm.warp(5);
        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 3);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.executionState.totalExecuted, 100e6);
    }

    // ============ Sender Cancellation ============

    function testSenderCanCancelMandate() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.CANCELLED));
    }

    // ============ Execution Pause ============

    function testExecutionPauseAllowsCancellation() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(admin);
        mandate.pauseExecution();

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.CANCELLED));
    }

    // ============ Policy Hash ============

    function testPolicyHashStoredAndVerifiable() public {
        uint256 startAt = block.timestamp;
        uint256 endAt = startAt + 365 days;

        bytes32 expectedHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, startAt, endAt);

        Mandate.Policy memory p = mandate.getPolicy(mandateId);
        assertEq(p.policyHash, expectedHash);
    }

    // ============ Total Charged Tracking ============

    function testTotalChargedIncreasesWithExecutions() public {
        bytes32 mandateId = generateMandateId();
        _createVariableMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, 30e6, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.executionState.totalExecuted, 30e6);
    }
}
