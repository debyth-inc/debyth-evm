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
    address public payer = makeAddr("payer");
    address public payee = makeAddr("payee");

    uint256 constant TOTAL_LIMIT = 1000e6; // 1000 USDC
    uint256 constant AMOUNT_PER_DEBIT = 100e6; // 100 USDC
    uint256 constant FREQUENCY = 30 days;

    event MandateCreated(
        bytes32 indexed mandateId,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 totalLimit,
        uint256 amountPerDebit,
        uint256 frequency,
        uint256 startTime,
        uint256 endTime,
        Mandate.DebitType debitType,
        Mandate.Frequency frequencyType
    );

    event MandateExecuted(
        bytes32 indexed mandateId,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    // Helper function to generate bytes32 mandate IDs
    function generateMandateId() internal returns (bytes32) {
        return keccak256(abi.encodePacked("mandate-", mandateIdCounter++));
    }

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether USD", "USDT");

        // Deploy implementation
        Mandate implementation = new Mandate();

        // Prepare supported tokens
        address[] memory supportedTokens = new address[](2);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(usdt);

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(Mandate.initialize.selector, admin, supportedTokens);

        // Deploy proxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, initData);

        mandate = Mandate(address(proxy));

        // Setup roles
        vm.prank(admin);
        mandate.addExecutor(executor);

        // Give tokens to payer
        usdc.mint(payer, 10000e6);
        usdt.mint(payer, 10000e6);
        mandateIdCounter = 1;
    }

    function testCreateMandate() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();

        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit MandateCreated(
            mandateId,
            payer,
            payee,
            address(usdc),
            TOTAL_LIMIT,
            AMOUNT_PER_DEBIT,
            FREQUENCY,
            startTime,
            endTime,
            Mandate.DebitType.Variable,
            Mandate.Frequency.Monthly
        );

        bytes32 returnedMandateId = mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        assertEq(returnedMandateId, mandateId);

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.payer, payer);
        assertEq(m.payee, payee);
        assertEq(m.token, address(usdc));
        assertEq(m.totalLimit, TOTAL_LIMIT);
        assertEq(m.amountPerDebit, AMOUNT_PER_DEBIT);
        assertEq(m.frequency, FREQUENCY);
        assertEq(m.startTime, startTime);
        assertEq(m.endTime, endTime);
        assertTrue(m.isActive);
    }

    function testExecutePayment() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();

        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        ); // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId);

        uint256 paymentAmount = 50e6; // 50 USDC
        uint256 payerBalanceBefore = usdc.balanceOf(payer);
        uint256 payeeBalanceBefore = usdc.balanceOf(payee);

        // Execute payment
        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit MandateExecuted(mandateId, payer, payee, address(usdc), paymentAmount, block.timestamp);

        mandate.executeMandate(mandateId, paymentAmount);

        // Check balances
        assertEq(usdc.balanceOf(payer), payerBalanceBefore - paymentAmount);
        assertEq(usdc.balanceOf(payee), payeeBalanceBefore + paymentAmount);

        // Check mandate state
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, paymentAmount);
        assertEq(m.lastPaymentTime, block.timestamp);
    }

    function testCannotExecutePaymentTooEarly() public {
        // Create mandate with Fixed debit type to test frequency constraint
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Fixed, // Fixed mandates enforce frequency
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        ); // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId);

        // Execute first payment (Fixed requires exact amount)
        vm.prank(executor);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        // Try to execute second payment immediately (should fail due to frequency)
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_ExecutionTooEarly.selector);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        // Fast forward time and try again (should succeed)
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);
    }

    function testVariableMandateNoFrequencyRestriction() public {
        // Create variable mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable, // Variable mandates don't enforce frequency
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(payer);
        mandate.approveMandate(mandateId);

        // Execute first payment
        vm.prank(executor);
        mandate.executeMandate(mandateId, 30e6);

        // Variable mandates should allow immediate subsequent payments (no frequency restriction)
        vm.prank(executor);
        mandate.executeMandate(mandateId, 20e6);

        // Execute third payment immediately as well
        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6);

        // Verify total paid
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, 100e6);
    }

    function testFixedMandateImmediateExecutionThenFrequency() public {
        // Create Fixed mandate with daily frequency
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;
        uint256 dailyFrequency = 1 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: dailyFrequency,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Fixed,
                frequencyType: Mandate.Frequency.Daily,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(payer);
        mandate.approveMandate(mandateId);

        // First execution: Should work immediately (same block as creation)
        vm.prank(executor);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, AMOUNT_PER_DEBIT);
        assertEq(m.lastPaymentTime, block.timestamp);

        // Second execution immediately: Should FAIL (frequency constraint)
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_ExecutionTooEarly.selector);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        // Third execution after 23 hours: Should still FAIL
        vm.warp(block.timestamp + 23 hours);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_ExecutionTooEarly.selector);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        // Fourth execution after exactly 1 day: Should SUCCEED
        vm.warp(m.lastPaymentTime + dailyFrequency);
        vm.prank(executor);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, AMOUNT_PER_DEBIT * 2);
    }

    function testVariableMandateImmediateExecutionMultipleTimes() public {
        // Create Variable mandate - should allow multiple immediate executions
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: 30 days, // This should be ignored for Variable
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

        vm.prank(payer);
        mandate.approveMandate(mandateId);

        // First execution: Immediate (same block as creation)
        vm.prank(executor);
        mandate.executeMandate(mandateId, 40e6);

        // Second execution: Also immediate (no frequency check)
        vm.prank(executor);
        mandate.executeMandate(mandateId, 30e6);

        // Third execution: Also immediate (no frequency check)
        vm.prank(executor);
        mandate.executeMandate(mandateId, 20e6);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, 90e6);

        // All three payments happened in the same block
        assertEq(m.lastPaymentTime, block.timestamp);
    }

    function testCancelMandate() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId);

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
        mandate.executeMandate(mandateId, 50e6);
    }

    function testCanExecutePayment() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        ); // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId);

        // Check if payment can be executed
        (bool canExecute, string memory reason) = mandate.canExecuteMandate(mandateId, 50e6);
        assertTrue(canExecute);
        assertEq(reason, "");

        // Check without allowance
        vm.prank(payer);
        usdc.approve(address(mandate), 0);

        (canExecute, reason) = mandate.canExecuteMandate(mandateId, 50e6);
        assertFalse(canExecute);
        assertEq(reason, "Insufficient allowance");
    }

    function testPauseUnpause() public {
        // Pause contract
        vm.prank(admin);
        mandate.pause();

        // Try to create mandate (should fail)
        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Unpause
        vm.prank(admin);
        mandate.unpause();

        // Try to create mandate (should succeed)
        bytes32 mandateId2 = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId2,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId2);
    }

    function testToggleMandateState() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Approve tokens
        vm.prank(payer);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Approve mandate
        vm.prank(payer);
        mandate.approveMandate(mandateId);

        // Mandate should be active
        Mandate.MandateData memory mandateData = mandate.getMandate(mandateId);
        assertTrue(mandateData.isActive);

        // Toggle to pause (inactive)
        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit Mandate.MandateStateToggled(mandateId, executor, false, block.timestamp);
        mandate.toggleMandateState(mandateId);

        // Check state changed to inactive
        mandateData = mandate.getMandate(mandateId);
        assertFalse(mandateData.isActive);

        // Try to execute - should fail because inactive
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);

        // Toggle back to active
        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit Mandate.MandateStateToggled(mandateId, executor, true, block.timestamp);
        mandate.toggleMandateState(mandateId);

        // Check state changed back to active
        mandateData = mandate.getMandate(mandateId);
        assertTrue(mandateData.isActive);

        // Now execution should succeed
        vm.prank(executor);
        mandate.executeMandate(mandateId, AMOUNT_PER_DEBIT);
    }

    function testOnlyExecutorCanToggleMandateState() public {
        // Create mandate
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 365 days;

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            payer,
            mandateId,
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                amountPerDebit: AMOUNT_PER_DEBIT,
                frequency: FREQUENCY,
                startTime: startTime,
                endTime: endTime,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );

        // Try to toggle as non-executor (should fail)
        vm.prank(payer);
        vm.expectRevert();
        mandate.toggleMandateState(mandateId);

        // Try to toggle as another random address (should fail)
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        mandate.toggleMandateState(mandateId);
    }

    function testToggleMandateStateRevertForInvalidId() public {
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.toggleMandateState(bytes32(uint256(999)));
    }
}
