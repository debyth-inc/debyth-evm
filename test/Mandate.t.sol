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

contract MandateTest is Test {
    Mandate public mandate;
    MockERC20 public usdc;
    MockERC20 public usdt;

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public payer = makeAddr("payer");
    address public payee = makeAddr("payee");

    uint256 constant TOTAL_LIMIT = 1000e6; // 1000 USDC
    uint256 constant PER_PAYMENT_LIMIT = 100e6; // 100 USDC
    uint256 constant FREQUENCY = 30 days;

    event MandateCreated(
        uint256 indexed mandateId,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 totalLimit,
        uint256 perPaymentLimit,
        uint256 frequency,
        uint256 startTime,
        uint256 endTime,
        Mandate.DebitType debitType,
        Mandate.Frequency frequencyType
    );

    event PaymentExecuted(
        uint256 indexed mandateId,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether USD", "USDT");

        // Deploy implementation
        Mandate implementation = new Mandate();

        // Deploy factory
        MandateFactory factory = new MandateFactory(address(implementation));

        // Prepare supported tokens
        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(usdt);

        // Deploy mandate clone
        vm.prank(admin);
        address mandateClone = factory.deployMandateContract(supportedTokens);
        mandate = Mandate(mandateClone);

        // Setup roles
        vm.prank(admin);
        mandate.addExecutor(executor);

        // Give tokens to payer
        usdc.mint(payer, 10000e6);
        usdt.mint(payer, 10000e6);
    }

    function testCreateMandate() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit MandateCreated(
            1, payer, payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime, Mandate.DebitType.Variable, Mandate.Frequency.Monthly
        );

        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        assertEq(mandateId, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.payer, payer);
        assertEq(m.payee, payee);
        assertEq(m.token, address(usdc));
        assertEq(m.totalLimit, TOTAL_LIMIT);
        assertEq(m.perPaymentLimit, PER_PAYMENT_LIMIT);
        assertEq(m.frequency, FREQUENCY);
        assertEq(m.startTime, startTime);
        assertEq(m.endTime, endTime);
        assertTrue(m.isActive);
    }

    function testExecutePayment() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        uint256 paymentAmount = 50e6; // 50 USDC
        uint256 payerBalanceBefore = usdc.balanceOf(payer);
        uint256 payeeBalanceBefore = usdc.balanceOf(payee);

        // Execute payment
        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit PaymentExecuted(mandateId, payer, payee, address(usdc), paymentAmount, block.timestamp);

        mandate.executePayment(mandateId, paymentAmount);

        // Check balances
        assertEq(usdc.balanceOf(payer), payerBalanceBefore - paymentAmount);
        assertEq(usdc.balanceOf(payee), payeeBalanceBefore + paymentAmount);

        // Check mandate state
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, paymentAmount);
        assertEq(m.lastPaymentTime, block.timestamp);
    }

    function testCannotExecutePaymentTooEarly() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Execute first payment
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);

        // Try to execute second payment immediately (should fail)
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PaymentTooEarly.selector);
        mandate.executePayment(mandateId, 50e6);

        // Fast forward time and try again (should succeed)
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);
    }

    function testCancelMandate() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Cancel mandate
        vm.prank(payer);
        mandate.cancelMandate(mandateId);

        // Check mandate is inactive
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertFalse(m.isActive);

        // Try to execute payment (should fail)
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executePayment(mandateId, 50e6);
    }

    function testCanExecutePayment() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Check if payment can be executed
        (bool canExecute, string memory reason) = mandate.canExecutePayment(mandateId, 50e6);
        assertTrue(canExecute);
        assertEq(reason, "");

        // Check without allowance
        vm.prank(payer);
        usdc.approve(address(mandate), 0);

        (canExecute, reason) = mandate.canExecutePayment(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Insufficient allowance");
    }

    function testGetUserMandates() public {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        // Create multiple mandates
        vm.startPrank(payer);
        uint256 mandateId1 = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        uint256 mandateId2 = mandate.createMandate(Mandate.CreateMandateParams({
            payee: payee,
            token: address(usdt),
            totalLimit: TOTAL_LIMIT,
            perPaymentLimit: PER_PAYMENT_LIMIT,
            frequency: FREQUENCY,
            startTime: startTime,
            endTime: endTime,
            debitType: Mandate.DebitType.Variable,
            frequencyType: Mandate.Frequency.Monthly,
            isUnlimitedSpend: false,
            authority: address(0)
        }));
        vm.stopPrank();

        // Get user mandates
        uint256[] memory userMandates = mandate.getUserMandates(payer);
        assertEq(userMandates.length, 2);
        assertEq(userMandates[0], mandateId1);
        assertEq(userMandates[1], mandateId2);

        // Get active mandates
        uint256[] memory activeMandates = mandate.getUserActiveMandates(payer);
        assertEq(activeMandates.length, 2);
    }

    function testPauseUnpause() public {
        // Pause contract
        vm.prank(admin);
        mandate.pause();

        // Try to create mandate (should fail)
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Unpause
        vm.prank(admin);
        mandate.unpause();

        // Try to create mandate (should succeed)
        vm.prank(payer);
        mandate.createMandate(Mandate.CreateMandateParams({
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
        }));
    }

    function testApprovalHealthMonitoring() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Approve only enough for 2 payments (below low threshold of 3)
        uint256 lowApproval = PER_PAYMENT_LIMIT * 2;
        vm.prank(payer);
        usdc.approve(address(mandate), lowApproval);

        // Check approval health
        (uint256 currentAllowance, uint256 paymentsRemaining, uint256 recommendedTopUp, bool isHealthy) =
            mandate.getApprovalHealth(mandateId);

        assertEq(currentAllowance, lowApproval);
        assertEq(paymentsRemaining, 2);
        assertFalse(isHealthy); // Should be unhealthy (below threshold of 3)
        assertTrue(recommendedTopUp > 0);
    }

    function testApprovalLowWarning() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Approve enough for exactly 3 payments (at low threshold)
        uint256 lowApproval = PER_PAYMENT_LIMIT * 3;
        vm.prank(payer);
        usdc.approve(address(mandate), lowApproval);

        // Execute payment - should trigger low warning
        vm.prank(executor);
        vm.expectEmit(true, false, false, false);
        emit Mandate.ApprovalLowWarning(mandateId, 0, 0, 0); // We don't check exact values
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    function testAutoPauseOnCriticalAllowance() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Approve enough for exactly 2 payments
        uint256 criticalApproval = PER_PAYMENT_LIMIT * 2;
        vm.prank(payer);
        usdc.approve(address(mandate), criticalApproval);

        // Execute first payment - should trigger auto-pause after payment
        vm.prank(executor);
        vm.expectEmit(true, false, false, false);
        emit Mandate.MandateAutoPaused(mandateId, "Insufficient allowance for future payments");
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Try to execute second payment - should fail due to system pause
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_SystemPaused.selector);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    function testUnpauseMandate() public {
        // Create mandate and trigger auto-pause
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Trigger auto-pause
        vm.prank(payer);
        usdc.approve(address(mandate), PER_PAYMENT_LIMIT * 2);

        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Top up approval
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Unpause mandate
        vm.prank(payer);
        vm.expectEmit(true, true, false, false);
        emit Mandate.MandateUnpaused(mandateId, payer);
        mandate.unpauseMandate(mandateId);

        // Should be able to execute payment now
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    function testSetApprovalThresholds() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Set custom thresholds
        vm.prank(payer);
        vm.expectEmit(true, false, false, true);
        emit Mandate.ApprovalThresholdsUpdated(mandateId, 5, 2);
        mandate.setApprovalThresholds(mandateId, 5, 2);

        // Verify thresholds were set
        Mandate.ApprovalSettings memory settings = mandate.getApprovalSettings(mandateId);
        assertEq(settings.lowAllowanceThreshold, 5);
        assertEq(settings.criticalThreshold, 2);
    }

    function testCalculateRecommendedTopUp() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(Mandate.CreateMandateParams({
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
        }));

        // Calculate recommended top-up for 6 payments
        uint256 recommended = mandate.calculateRecommendedTopUp(mandateId, 6);

        // Should be 6 payments + 10% buffer
        uint256 expected = (PER_PAYMENT_LIMIT * 6 * 110) / 100;
        assertEq(recommended, expected);
    }
}
