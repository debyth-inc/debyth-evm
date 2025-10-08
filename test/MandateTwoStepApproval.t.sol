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

contract MandateTwoStepApprovalTest is Test {
    Mandate public mandate;
    MockERC20 public usdc;

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor"); // Business/authority
    address public user = makeAddr("user"); // End user
    address public payee = makeAddr("payee"); // Service provider

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

        usdc.mint(user, 10000e6);
    }

    // ============ Two-Step Approval Flow Tests ============

    function testBusinessCreatesMandate() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        // Business creates mandate for user
        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        // Check mandate exists and is not approved/active yet
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.payer, user);
        assertEq(m.payee, payee);
        assertEq(m.authority, executor);
        assertFalse(m.isApproved);
        assertFalse(m.isActive);
    }

    function testUserApprovesMandate() public {
        // Step 1: Business creates mandate
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        // Step 2: User approves tokens
        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Step 3: User approves mandate
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit Mandate.MandateApproved(mandateId, user, block.timestamp);
        mandate.approveMandate(mandateId);

        // Check mandate is now approved and active
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertTrue(m.isApproved);
        assertTrue(m.isActive);
    }

    function testCannotApproveWithoutTokenApproval() public {
        // Business creates mandate
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        // User tries to approve mandate without token approval
        vm.prank(user);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandate.approveMandate(mandateId);
    }

    function testCannotApproveAlreadyApprovedMandate() public {
        // Create and approve mandate
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(user);
        mandate.approveMandate(mandateId);

        // Try to approve again
        vm.prank(user);
        vm.expectRevert(Mandate.Mandate_AlreadyApproved.selector);
        mandate.approveMandate(mandateId);
    }

    function testCannotApproveOtherUserMandate() public {
        address otherUser = makeAddr("otherUser");

        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        // Other user tries to approve
        vm.prank(otherUser);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.approveMandate(mandateId);
    }

    function testCannotExecutePaymentBeforeApproval() public {
        // Business creates mandate
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        // User approves tokens but not mandate
        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Try to execute payment before approval
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_NotApproved.selector);
        mandate.executePayment(mandateId, 50e6);
    }

    function testCompleteFlowWithPayment() public {
        // Step 1: Business creates mandate
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        uint256 mandateId = mandate.createMandateForUser(user, params);

        // Step 2: User approves tokens
        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Step 3: User approves mandate
        vm.prank(user);
        mandate.approveMandate(mandateId);

        // Step 4: Business executes payment
        uint256 payeeBalanceBefore = usdc.balanceOf(payee);

        vm.prank(executor);
        mandate.executePayment(mandateId, 50e6);

        // Verify payment executed
        assertEq(usdc.balanceOf(payee), payeeBalanceBefore + 50e6);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, 50e6);
    }

    function testOnlyExecutorCanCreateMandateForUser() public {
        address unauthorized = makeAddr("unauthorized");

        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.createMandateForUser(user, params);
    }

    function testUserCreatedMandateIsAutoApproved() public {
        // When user creates their own mandate, it should be auto-approved
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(user);
        uint256 mandateId = mandate.createMandate(params);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertTrue(m.isApproved); // Auto-approved
        assertTrue(m.isActive);
        assertEq(m.payer, user);
    }
}
