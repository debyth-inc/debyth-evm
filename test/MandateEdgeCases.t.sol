// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Mandate} from "../src/Mandate.sol";
import {MandateFactory} from "../src/MandateFactory.sol";

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

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public payer = makeAddr("payer");
    address public payee = makeAddr("payee");

    uint256 constant TOTAL_LIMIT = 1000e6;
    uint256 constant PER_PAYMENT_LIMIT = 100e6;
    uint256 constant FREQUENCY = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");

        Mandate implementation = new Mandate();
        MandateFactory factory = new MandateFactory(address(implementation));

        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        vm.prank(admin);
        address mandateClone = factory.deployMandateContract(supportedTokens);
        mandate = Mandate(mandateClone);

        vm.prank(admin);
        mandate.addExecutor(executor);

        usdc.mint(payer, 10000e6);
    }

    // ============ Timing Edge Cases ============

    function testExecutePaymentExactlyAtStartTime() public {
        uint256 startTime = block.timestamp + 1 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: startTime + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Before start time
        vm.expectRevert(Mandate.Mandate_PaymentTooEarly.selector);
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);

        // Exactly at start time
        vm.warp(startTime);
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);
    }

    function testExecutePaymentExactlyAtEndTime() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // At end time
        vm.warp(endTime);
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);
    }

    function testCannotExecutePaymentAfterEndTime() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // After end time
        vm.warp(endTime + 1);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateExpired.selector);
        mandate.executePayment(mandateId, 50e6);
    }

    function testExecutePaymentExactlyAtFrequencyInterval() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // First payment
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);

        uint256 firstPaymentTime = block.timestamp;

        // Try before frequency
        vm.warp(firstPaymentTime + FREQUENCY - 1);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PaymentTooEarly.selector);
        mandate.executePayment(mandateId, 50e6);

        // Exactly at frequency
        vm.warp(firstPaymentTime + FREQUENCY);
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);
    }

    // ============ Limit Edge Cases ============

    function testExecutePaymentHittingExactTotalLimit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Disable auto-pause
        vm.prank(payer);
        mandate.setAutoPause(mandateId, false);

        // Execute payments up to exact limit
        uint256 remaining = TOTAL_LIMIT;
        while (remaining > 0) {
            uint256 amount = remaining >= PER_PAYMENT_LIMIT ? PER_PAYMENT_LIMIT : remaining;
            vm.prank(executor);
            mandate.executePayment(mandateId, amount);
            remaining -= amount;

            if (remaining > 0) {
                vm.warp(block.timestamp + FREQUENCY);
            }
        }

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, TOTAL_LIMIT);

        // Try one more payment
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PaymentExceedsLimit.selector);
        mandate.executePayment(mandateId, 1);
    }

    function testExecutePaymentWithRemainingLessThanPerPaymentLimit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Disable auto-pause
        vm.prank(payer);
        mandate.setAutoPause(mandateId, false);

        // Execute 9 full payments (900e6)
        for (uint256 i = 0; i < 9; i++) {
            if (i > 0) {
                vm.warp(block.timestamp + FREQUENCY);
            }
            vm.prank(executor);
            mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
        }

        // Remaining: 100e6, can execute one more full payment
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, TOTAL_LIMIT);
    }

    function testInsufficientBalanceRevert() public {
        address poorPayer = makeAddr("poorPayer");
        usdc.mint(poorPayer, 10e6); // Only 10 USDC

        vm.prank(poorPayer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(poorPayer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Try to execute payment larger than balance
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientBalance.selector);
        mandate.executePayment(mandateId, 50e6);
    }

    function testInsufficientAllowanceRevert() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Approve less than payment amount
        vm.prank(payer);
        usdc.approve(address(mandate), 10e6);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandate.executePayment(mandateId, 50e6);
    }

    // ============ Approval Health Edge Cases ============

    function testApprovalHealthWithZeroAllowance() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        (uint256 currentAllowance, uint256 paymentsRemaining,, bool isHealthy) = mandate.getApprovalHealth(mandateId);

        assertEq(currentAllowance, 0);
        assertEq(paymentsRemaining, 0);
        assertFalse(isHealthy);
    }

    function testCalculateRecommendedTopUpWithZeroPaymentsAhead() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        uint256 recommended = mandate.calculateRecommendedTopUp(mandateId, 0);
        assertEq(recommended, 0);
    }

    function testCalculateRecommendedTopUpRespectsTotalLimit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Request recommendation for 100 payments (way more than total limit allows)
        uint256 recommended = mandate.calculateRecommendedTopUp(mandateId, 100);

        // Should not exceed total limit
        assertTrue(recommended <= TOTAL_LIMIT);
    }

    function testCalculateRecommendedTopUpRespectsRemainingLimit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Disable auto-pause
        vm.prank(payer);
        mandate.setAutoPause(mandateId, false);

        // Execute half of total limit
        for (uint256 i = 0; i < 5; i++) {
            if (i > 0) {
                vm.warp(block.timestamp + FREQUENCY);
            }
            vm.prank(executor);
            mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
        }

        // Request recommendation for many payments
        uint256 recommended = mandate.calculateRecommendedTopUp(mandateId, 20);
        uint256 remaining = TOTAL_LIMIT - (5 * PER_PAYMENT_LIMIT);

        // Should not exceed remaining limit
        assertTrue(recommended <= remaining);
    }

    // ============ View Function Edge Cases ============

    function testCanExecutePaymentWithInvalidMandateId() public view {
        (bool canExecute, string memory reason) = mandate.canExecutePayment(999, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Invalid mandate ID");
    }

    function testCanExecutePaymentOnCanceledMandate() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        mandate.cancelMandate(mandateId);

        (bool canExecute, string memory reason) = mandate.canExecutePayment(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Mandate not active");
    }

    function testCanExecutePaymentOnExpiredMandate() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.warp(endTime + 1);

        (bool canExecute, string memory reason) = mandate.canExecutePayment(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Mandate expired");
    }

    function testCanExecutePaymentForFixedDebit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Fixed,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Wrong amount
        (bool canExecute, string memory reason) = mandate.canExecutePayment(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Fixed debit requires exact amount");

        // Correct amount
        (canExecute, reason) = mandate.canExecutePayment(mandateId, PER_PAYMENT_LIMIT);
        assertTrue(canExecute);
        assertEq(reason, "");
    }

    function testCanExecutePaymentForVariableDebit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Zero amount
        (bool canExecute, string memory reason) = mandate.canExecutePayment(mandateId, 0);
        assertFalse(canExecute);
        assertEq(reason, "Variable debit amount invalid");

        // Exceeding limit
        (canExecute, reason) = mandate.canExecutePayment(mandateId, PER_PAYMENT_LIMIT + 1);
        assertFalse(canExecute);
        assertEq(reason, "Variable debit amount invalid");

        // Valid amount
        (canExecute, reason) = mandate.canExecutePayment(mandateId, 50e6);
        assertTrue(canExecute);
        assertEq(reason, "");
    }

    // ============ User Mandate Tracking ============

    function testGetUserActiveMandatesFiltersExpired() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;

        // Create short-lived mandate
        vm.prank(payer);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Create long-lived mandate
        vm.prank(payer);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: startTime + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        uint256[] memory activeBefore = mandate.getUserActiveMandates(payer);
        assertEq(activeBefore.length, 2);

        // Warp past first mandate expiration
        vm.warp(endTime + 1);

        uint256[] memory activeAfter = mandate.getUserActiveMandates(payer);
        assertEq(activeAfter.length, 1);
    }

    function testGetUserActiveMandatesFiltersCanceled() public {
        vm.prank(payer);
        uint256 mandateId1 = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        uint256[] memory activeBefore = mandate.getUserActiveMandates(payer);
        assertEq(activeBefore.length, 2);

        // Cancel first mandate
        vm.prank(payer);
        mandate.cancelMandate(mandateId1);

        uint256[] memory activeAfter = mandate.getUserActiveMandates(payer);
        assertEq(activeAfter.length, 1);
    }

    // ============ Factory Edge Cases ============

    function testFactoryWithEmptyTokenArray() public {
        Mandate implementation = new Mandate();
        MandateFactory factory = new MandateFactory(address(implementation));

        address[] memory emptyTokens = new address[](0);

        vm.prank(admin);
        address newMandate = factory.deployMandateContract(emptyTokens);

        assertTrue(newMandate != address(0));
    }

    function testFactoryGetMandateContractAtInvalidIndex() public {
        Mandate implementation = new Mandate();
        MandateFactory factory = new MandateFactory(address(implementation));

        vm.expectRevert("Index out of bounds");
        factory.getMandateContractAt(0);
    }

    // ============ Multiple Executors Test ============

    function testMultipleExecutorsCanExecutePayments() public {
        address executor2 = makeAddr("executor2");

        vm.prank(admin);
        mandate.addExecutor(executor2);

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // First executor
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);

        // Second executor
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor2);
        mandate.executePayment(mandateId, 50e6);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, 100e6);
    }

    // ============ Integer Boundary Tests ============

    function testCreateMandateWithMaxUint256Frequency() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: type(uint256).max,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.frequency, type(uint256).max);
    }

    function testUnlimitedSpendWithLargePayments() public {
        uint256 largeAmount = 1000000e6; // 1 million USDC

        usdc.mint(payer, largeAmount * 10);

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: 0,
                perPaymentLimit: largeAmount,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: true,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), type(uint256).max);

        // Execute large payment
        vm.prank(executor);
        mandate.executePayment(mandateId, largeAmount);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, largeAmount);
    }

    // ============ Event Emission Tests ============

    function testMandateCreatedEventEmitted() public {
        vm.expectEmit(true, true, true, true);
        emit Mandate.MandateCreated(
            1,
            payer,
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            block.timestamp,
            block.timestamp + 365 days,
            Mandate.DebitType.Variable,
            Mandate.Frequency.Monthly
        );

        vm.prank(payer);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );
    }

    function testExecutorAddedEventEmitted() public {
        address newExecutor = makeAddr("newExecutor");

        vm.expectEmit(true, false, false, false);
        emit Mandate.ExecutorAdded(newExecutor);

        vm.prank(admin);
        mandate.addExecutor(newExecutor);
    }

    function testExecutorRemovedEventEmitted() public {
        vm.expectEmit(true, false, false, false);
        emit Mandate.ExecutorRemoved(executor);

        vm.prank(admin);
        mandate.removeExecutor(executor);
    }

    function testTokenSupportedEventEmitted() public {
        address newToken = makeAddr("newToken");

        vm.expectEmit(true, false, false, true);
        emit Mandate.TokenSupported(newToken, true);

        vm.prank(admin);
        mandate.setSupportedToken(newToken, true);
    }
}
