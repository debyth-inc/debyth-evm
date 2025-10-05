// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MandateFactory.sol";
import "../src/Mandate.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MandateIntegrationTest is Test {
    MandateFactory public factory;
    Mandate public implementation;
    Mandate public mandateContract;
    MockERC20 public usdc;

    address public factoryOwner = makeAddr("factoryOwner");
    address public payer = makeAddr("payer");
    address public payee = makeAddr("payee");
    address public executor = makeAddr("executor");

    uint256 constant TOTAL_LIMIT = 1000e6; // 1000 USDC
    uint256 constant PER_PAYMENT_LIMIT = 100e6; // 100 USDC
    uint256 constant FREQUENCY = 30 days;

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC");

        // Deploy implementation
        implementation = new Mandate();

        // Deploy factory
        vm.prank(factoryOwner);
        factory = new MandateFactory(address(implementation));

        // Deploy mandate contract for payer
        address[] memory supportedTokens = new address[](1);
        supportedTokens[0] = address(usdc);

        vm.prank(payer);
        address mandateAddr = factory.deployMandateContract(supportedTokens);
        mandateContract = Mandate(mandateAddr);

        // Setup executor
        vm.prank(payer);
        mandateContract.addExecutor(executor);

        // Give tokens to payer
        usdc.mint(payer, 10000e6);
    }

    function testFullMandateWorkflow() public {
        // 1. Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        assertEq(mandateId, 1);

        // 2. Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        // 3. Execute first payment
        uint256 paymentAmount = 50e6;
        uint256 payerBalanceBefore = usdc.balanceOf(payer);
        uint256 payeeBalanceBefore = usdc.balanceOf(payee);

        vm.prank(executor);
        mandateContract.executePayment(mandateId, paymentAmount);

        // Verify balances
        assertEq(usdc.balanceOf(payer), payerBalanceBefore - paymentAmount);
        assertEq(usdc.balanceOf(payee), payeeBalanceBefore + paymentAmount);

        // 4. Try to execute payment too early (should fail)
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PaymentTooEarly.selector);
        mandateContract.executePayment(mandateId, paymentAmount);

        // 5. Fast forward time and execute second payment
        vm.warp(block.timestamp + FREQUENCY);

        vm.prank(executor);
        mandateContract.executePayment(mandateId, paymentAmount);

        // Verify total paid
        Mandate.MandateData memory mandate = mandateContract.getMandate(mandateId);
        assertEq(mandate.totalPaid, paymentAmount * 2);

        // 6. Cancel mandate
        vm.prank(payer);
        mandateContract.cancelMandate(mandateId);

        // 7. Try to execute payment on canceled mandate (should fail)
        vm.warp(block.timestamp + FREQUENCY);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandateContract.executePayment(mandateId, paymentAmount);
    }

    function testMandateWithInsufficientAllowance() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        // Don't approve tokens (or approve insufficient amount)
        vm.prank(payer);
        usdc.approve(address(mandateContract), 10e6); // Less than payment amount

        // Try to execute payment
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandateContract.executePayment(mandateId, 50e6);
    }

    function testMandateExceedingLimits() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        vm.prank(payer);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        // Disable auto-pause for this test to avoid interference
        vm.prank(payer);
        mandateContract.setAutoPause(mandateId, false);

        // Try to execute payment exceeding per-payment limit
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PaymentExceedsLimit.selector);
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT + 1);

        // Execute payments up to total limit
        uint256 paymentsToMake = TOTAL_LIMIT / PER_PAYMENT_LIMIT;

        for (uint256 i = 0; i < paymentsToMake; i++) {
            vm.prank(executor);
            mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);

            if (i < paymentsToMake - 1) {
                vm.warp(block.timestamp + FREQUENCY);
            }
        }

        // Try to execute one more payment (should fail - exceeds total limit)
        vm.warp(block.timestamp + FREQUENCY);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PaymentExceedsLimit.selector);
        mandateContract.executePayment(mandateId, 1);
    }

    function testMandateExpiration() public {
        // Create mandate with short duration
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 1 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        vm.prank(payer);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        // Fast forward past expiration
        vm.warp(endTime + 1);

        // Try to execute payment on expired mandate
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateExpired.selector);
        mandateContract.executePayment(mandateId, 50e6);
    }

    function testUserRevokeAllowance() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        // Execute first payment successfully
        vm.prank(executor);
        mandateContract.executePayment(mandateId, 50e6);

        // User revokes allowance (simulating user stopping the mandate)
        vm.prank(payer);
        usdc.approve(address(mandateContract), 0);

        // Try to execute second payment (should fail)
        vm.warp(block.timestamp + FREQUENCY);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandateContract.executePayment(mandateId, 50e6);
    }

    function testCanExecutePaymentView() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        // Check without allowance
        (bool canExecute, string memory reason) = mandateContract.canExecutePayment(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Insufficient allowance");

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        // Check with allowance
        (canExecute, reason) = mandateContract.canExecutePayment(mandateId, 50e6);
        assertTrue(canExecute);
        assertEq(reason, "");

        // Execute payment
        vm.prank(executor);
        mandateContract.executePayment(mandateId, 50e6);

        // Check frequency constraint
        (canExecute, reason) = mandateContract.canExecutePayment(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Payment too early - frequency constraint");
    }

    function testApprovalHealthWorkflow() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        // 1. Start with healthy approval (10 payments worth)
        uint256 healthyApproval = PER_PAYMENT_LIMIT * 10;
        vm.prank(payer);
        usdc.approve(address(mandateContract), healthyApproval);

        // Check health - should be healthy
        (,, uint256 recommendedTopUp, bool isHealthy) = mandateContract.getApprovalHealth(mandateId);
        assertTrue(isHealthy);
        assertTrue(recommendedTopUp > 0);

        // 2. Execute several payments to reduce allowance
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(executor);
            mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);
            vm.warp(block.timestamp + FREQUENCY);
        }

        // 3. Should now be in low allowance territory (3 payments left)
        (, uint256 paymentsRemaining,, bool stillHealthy) = mandateContract.getApprovalHealth(mandateId);
        assertEq(paymentsRemaining, 3);
        assertFalse(stillHealthy);

        // 4. Execute one more payment - should trigger low warning
        vm.prank(executor);
        vm.expectEmit(true, false, false, false);
        emit Mandate.ApprovalLowWarning(mandateId, 0, 0, 0);
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // 5. Execute another payment - should trigger auto-pause
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        vm.expectEmit(true, false, false, false);
        emit Mandate.MandateAutoPaused(mandateId, "Insufficient allowance for future payments");
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // 6. User tops up approval and unpauses
        vm.prank(payer);
        usdc.approve(address(mandateContract), TOTAL_LIMIT);

        vm.prank(payer);
        mandateContract.unpauseMandate(mandateId);

        // 7. Should be able to continue payments
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    function testCustomApprovalThresholds() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        vm.prank(payer);
        uint256 mandateId = mandateContract.createMandate(
            payee, address(usdc), TOTAL_LIMIT, PER_PAYMENT_LIMIT, FREQUENCY, startTime, endTime
        );

        // Set custom thresholds: warn at 5, pause at 2
        vm.prank(payer);
        mandateContract.setApprovalThresholds(mandateId, 5, 2);

        // Approve exactly 6 payments worth
        vm.prank(payer);
        usdc.approve(address(mandateContract), PER_PAYMENT_LIMIT * 6);

        // Execute 2 payments - should trigger warning after second payment
        vm.prank(executor);
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);

        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        vm.expectEmit(true, false, false, false);
        emit Mandate.ApprovalLowWarning(mandateId, 0, 0, 0);
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Execute 2 more payments - should trigger auto-pause after 4th payment
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);

        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        vm.expectEmit(true, false, false, false);
        emit Mandate.MandateAutoPaused(mandateId, "Insufficient allowance for future payments");
        mandateContract.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }
}
