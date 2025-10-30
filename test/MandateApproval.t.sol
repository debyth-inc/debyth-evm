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

contract MandateApprovalTest is Test {
    Mandate public mandate;
    MockERC20 public usdc;

    uint256 public mandateIdCounter;

    function generateMandateId() internal returns (bytes32) {
        return keccak256(abi.encodePacked("mandate-", mandateIdCounter++));
    }

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public user = makeAddr("user");
    address public payee = makeAddr("payee");

    uint256 constant TOTAL_LIMIT = 1000e6;
    uint256 constant AMOUNT_PER_DEBIT = 100e6;
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
        mandateIdCounter = 0;
    }

    function testBusinessCreatesMandate() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
            authority: executor
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.payer, user);
        assertEq(m.payee, payee);
        assertEq(m.authority, executor);
        assertFalse(m.isApproved);
        assertFalse(m.isActive);
    }

    function testUserApprovesMandate() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        vm.startPrank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);
        vm.expectEmit(false, true, false, true);
        emit Mandate.MandateApproved(mandateId, user, block.timestamp);
        mandate.approveMandate(mandateId);
        vm.stopPrank();

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertTrue(m.isApproved);
        assertTrue(m.isActive);
    }

    function testBackendCanApproveMandateAfterUserApprovesTokens() public {
        address backend = makeAddr("backend");

        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        // User approves tokens
        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        // Backend activates mandate (no user interaction)
        vm.prank(backend);
        vm.expectEmit(false, true, false, true);
        emit Mandate.MandateApproved(mandateId, user, block.timestamp);
        mandate.approveMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertTrue(m.isApproved);
        assertTrue(m.isActive);
    }

    function testCannotApproveAlreadyApprovedMandate() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        vm.startPrank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);
        mandate.approveMandate(mandateId);

        vm.expectRevert(Mandate.Mandate_AlreadyApproved.selector);
        mandate.approveMandate(mandateId);
        vm.stopPrank();
    }

    function testCannotExecutePaymentBeforeApproval() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_NotApproved.selector);
        mandate.executeMandate(mandateId, 50e6);
    }

    function testCompleteFlowWithPayment() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        vm.startPrank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT);
        mandate.approveMandate(mandateId);
        vm.stopPrank();

        uint256 payeeBalanceBefore = usdc.balanceOf(payee);

        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6);

        assertEq(usdc.balanceOf(payee), payeeBalanceBefore + 50e6);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, 50e6);
    }


    function testCannotApproveMandateWithoutTokenApproval() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        vm.prank(user);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandate.approveMandate(mandateId);
    }

    function testCannotApproveMandateWithInsufficientAllowance() public {
        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(executor);
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);

        vm.prank(user);
        usdc.approve(address(mandate), TOTAL_LIMIT / 2);

        vm.prank(user);
        vm.expectRevert(Mandate.Mandate_InsufficientAllowance.selector);
        mandate.approveMandate(mandateId);
    }

    function testOnlyExecutorCanCreateMandate() public {
        address unauthorized = makeAddr("unauthorized");

        Mandate.CreateMandateParams memory params = Mandate.CreateMandateParams({
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
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        bytes32 mandateId = generateMandateId();
        mandate.createMandate(user, mandateId, params);
    }
}
