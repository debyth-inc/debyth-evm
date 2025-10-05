// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/Mandate.sol";
import "../src/MandateFactory.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
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
        uint256 endTime
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
            1,
            payer,
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
        uint256 mandateId = mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
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
        uint256 mandateId = mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);
        
        uint256 paymentAmount = 50e6; // 50 USDC
        uint256 payerBalanceBefore = usdc.balanceOf(payer);
        uint256 payeeBalanceBefore = usdc.balanceOf(payee);
        
        // Execute payment
        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit PaymentExecuted(
            mandateId,
            payer,
            payee,
            address(usdc),
            paymentAmount,
            block.timestamp
        );
        
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
        uint256 mandateId = mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
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
        uint256 mandateId = mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
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
        uint256 mandateId = mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
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
        uint256 mandateId1 = mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
        
        uint256 mandateId2 = mandate.createMandate(
            payee,
            address(usdt),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            startTime,
            endTime
        );
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
        vm.expectRevert("Pausable: paused");
        mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            block.timestamp,
            block.timestamp + 365 days
        );
        
        // Unpause
        vm.prank(admin);
        mandate.unpause();
        
        // Try to create mandate (should succeed)
        vm.prank(payer);
        mandate.createMandate(
            payee,
            address(usdc),
            TOTAL_LIMIT,
            PER_PAYMENT_LIMIT,
            FREQUENCY,
            block.timestamp,
            block.timestamp + 365 days
        );
    }
}