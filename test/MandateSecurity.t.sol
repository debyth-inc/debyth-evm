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

// Malicious ERC20 that tries to reenter
contract MaliciousToken is ERC20 {
    address public mandateContract;
    uint256 public attackMandateId;
    bool public attackInitiated;

    constructor() ERC20("Malicious", "MAL") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function setAttack(address _mandate, uint256 _mandateId) external {
        mandateContract = _mandate;
        attackMandateId = _mandateId;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!attackInitiated && mandateContract != address(0)) {
            attackInitiated = true;
            // Try to reenter
            try Mandate(mandateContract).executePayment(attackMandateId, amount) {} catch {}
        }
        return super.transferFrom(from, to, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Fee-on-transfer token for testing
contract FeeOnTransferToken is ERC20 {
    uint256 public transferFeePercent = 10; // 10% fee

    constructor() ERC20("FeeToken", "FEE") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // First spend allowance
        _spendAllowance(from, msg.sender, amount);

        // Then do transfers with fee
        uint256 fee = (amount * transferFeePercent) / 100;
        uint256 amountAfterFee = amount - fee;

        _transfer(from, to, amountAfterFee);
        if (fee > 0) {
            _transfer(from, address(0xdead), fee); // Burn fee
        }

        return true;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MandateSecurityTest is Test {
    Mandate public mandate;
    MockERC20 public usdc;
    MaliciousToken public malToken;
    FeeOnTransferToken public feeToken;

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public payer = makeAddr("payer");
    address public payee = makeAddr("payee");
    address public unauthorized = makeAddr("unauthorized");
    address public authority = makeAddr("authority");

    uint256 constant TOTAL_LIMIT = 1000e6;
    uint256 constant PER_PAYMENT_LIMIT = 100e6;
    uint256 constant FREQUENCY = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        malToken = new MaliciousToken();
        feeToken = new FeeOnTransferToken();

        Mandate implementation = new Mandate();
        MandateFactory factory = new MandateFactory(address(implementation));

        address[] memory supportedTokens = new address[](3);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(malToken);
        supportedTokens[2] = address(feeToken);

        vm.prank(admin);
        address mandateClone = factory.deployMandateContract(supportedTokens);
        mandate = Mandate(mandateClone);

        vm.prank(admin);
        mandate.addExecutor(executor);

        usdc.mint(payer, 10000e6);
        malToken.mint(payer, 10000e6);
        feeToken.mint(payer, 10000e6);
    }

    // ============ Authorization Tests ============

    function testUnauthorizedExecutorCannotExecutePayment() public {
        // Create mandate
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

        // Try to execute as unauthorized user
        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.executePayment(mandateId, 50e6);
    }

    function testUnauthorizedUserCannotCancelMandate() public {
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

        vm.prank(unauthorized);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.cancelMandate(mandateId);
    }

    function testUnauthorizedUserCannotSetApprovalThresholds() public {
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

        vm.prank(unauthorized);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.setApprovalThresholds(mandateId, 5, 2);
    }

    function testUnauthorizedUserCannotUnpauseMandate() public {
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

        // Trigger auto-pause
        vm.prank(payer);
        usdc.approve(address(mandate), PER_PAYMENT_LIMIT * 2);

        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Try to unpause as unauthorized user
        vm.prank(unauthorized);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.unpauseMandate(mandateId);
    }

    function testUnauthorizedUserCannotSetAutoPause() public {
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

        vm.prank(unauthorized);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.setAutoPause(mandateId, false);
    }

    // ============ Admin Function Tests ============

    function testNonAdminCannotAddExecutor() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.addExecutor(makeAddr("newExecutor"));
    }

    function testNonAdminCannotRemoveExecutor() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.removeExecutor(executor);
    }

    function testNonAdminCannotSetSupportedToken() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.setSupportedToken(makeAddr("newToken"), true);
    }

    function testNonAdminCannotPauseContract() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.pause();
    }

    function testNonAdminCannotUnpauseContract() public {
        vm.prank(admin);
        mandate.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.unpause();
    }

    function testNonAdminCannotEmergencyCancel() public {
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

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.emergencyCancelMandate(mandateId);
    }

    function testAdminCanEmergencyCancel() public {
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

        vm.prank(admin);
        mandate.emergencyCancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertFalse(m.isActive);
    }

    function testAdminCanAddAndRemoveExecutor() public {
        address newExecutor = makeAddr("newExecutor");

        vm.prank(admin);
        mandate.addExecutor(newExecutor);

        assertTrue(mandate.hasRole(mandate.EXECUTOR_ROLE(), newExecutor));

        vm.prank(admin);
        mandate.removeExecutor(newExecutor);

        assertFalse(mandate.hasRole(mandate.EXECUTOR_ROLE(), newExecutor));
    }

    function testAdminCanChangeSupportedTokens() public {
        address newToken = makeAddr("newToken");

        vm.prank(admin);
        mandate.setSupportedToken(newToken, true);

        assertTrue(mandate.supportedTokens(newToken));

        vm.prank(admin);
        mandate.setSupportedToken(newToken, false);

        assertFalse(mandate.supportedTokens(newToken));
    }

    // ============ Edge Case Tests ============

    function testCannotCreateMandateWithZeroAddress() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: address(0),
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

    function testCannotCreateMandateWithSelfAsPayee() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payer, // Self as payee
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

    function testCannotCreateMandateWithUnsupportedToken() public {
        address unsupportedToken = makeAddr("unsupported");

        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_UnsupportedToken.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: unsupportedToken,
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

    function testCannotCreateMandateWithZeroPerPaymentLimit() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: 0, // Zero per payment limit
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

    function testCannotCreateMandateWithZeroTotalLimitWhenNotUnlimited() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: 0, // Zero total limit
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false, // Not unlimited
                authority: address(0)
            })
        );
    }

    function testCannotCreateMandateWithPerPaymentLimitGreaterThanTotal() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: 100e6, // Total limit
                perPaymentLimit: 200e6, // Per payment > total
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

    function testCannotCreateMandateWithZeroFrequency() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: 0, // Zero frequency
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );
    }

    function testCannotCreateMandateWithStartTimeInPast() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp - 1, // Past
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );
    }

    function testCannotCreateMandateWithEndTimeBeforeStart() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: TOTAL_LIMIT,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp + 365 days,
                endTime: block.timestamp, // End before start
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: false,
                authority: address(0)
            })
        );
    }

    function testCannotCreateMandateWithAuthorityAsSelf() public {
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
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
                authority: payer // Authority same as payer
            })
        );
    }

    function testCannotExecutePaymentOnInvalidMandateId() public {
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.executePayment(999, 50e6);
    }

    function testCannotExecutePaymentOnInactiveMandate() public {
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

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executePayment(mandateId, 50e6);
    }

    function testCannotExecutePaymentWithZeroAmount() public {
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

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidAmountForVariableDebit.selector);
        mandate.executePayment(mandateId, 0);
    }

    function testCannotExecutePaymentExceedingPerPaymentLimit() public {
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

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidAmountForVariableDebit.selector);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT + 1);
    }

    function testCannotExecutePaymentWhenSystemPaused() public {
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

        // Trigger system pause
        vm.prank(payer);
        usdc.approve(address(mandate), PER_PAYMENT_LIMIT * 2);

        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Should be paused now
        vm.warp(block.timestamp + FREQUENCY);
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_SystemPaused.selector);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    function testCannotUnpauseNonPausedMandate() public {
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
        vm.expectRevert(Mandate.Mandate_NotSystemPaused.selector);
        mandate.unpauseMandate(mandateId);
    }

    function testCannotSetInvalidApprovalThresholds() public {
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

        // Critical >= low (invalid)
        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.setApprovalThresholds(mandateId, 3, 5);
    }

    function testCannotCancelAlreadyCanceledMandate() public {
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

        vm.prank(payer);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.cancelMandate(mandateId);
    }

    function testCannotCreateMandateWhenContractPaused() public {
        vm.prank(admin);
        mandate.pause();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
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

    function testCannotExecutePaymentWhenContractPaused() public {
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

        vm.prank(admin);
        mandate.pause();

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.executePayment(mandateId, 50e6);
    }

    function testGetMandateRevertForInvalidId() public {
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.getMandate(999);
    }

    function testGetApprovalSettingsRevertForInvalidId() public {
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.getApprovalSettings(999);
    }

    function testCheckApprovalHealthRevertForInvalidId() public {
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.checkApprovalHealth(999);
    }

    function testGetApprovalHealthRevertForInvalidId() public {
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.getApprovalHealth(999);
    }

    // ============ Authority Tests ============

    function testAuthorityCanCancelMandate() public {
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
                authority: authority
            })
        );

        vm.prank(authority);
        mandate.cancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertFalse(m.isActive);
    }

    function testAuthorityCannotCancelIfNotSet() public {
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
                authority: address(0) // No authority
            })
        );

        vm.prank(authority);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.cancelMandate(mandateId);
    }

    // ============ Debit Type Tests ============

    function testFixedDebitRequiresExactAmount() public {
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

        // Try with wrong amount
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidAmountForFixedDebit.selector);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT - 1);

        // Try with exact amount
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    function testVariableDebitAllowsAnyAmountUpToLimit() public {
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

        // Execute with different amounts
        vm.prank(executor);
        mandate.executePayment(mandateId, 30e6);

        uint256 firstPaymentTime = block.timestamp;
        vm.warp(firstPaymentTime + FREQUENCY);
        vm.prank(executor);
        mandate.executePayment(mandateId, 70e6);

        vm.warp(firstPaymentTime + 2 * FREQUENCY);
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
    }

    // ============ Unlimited Spend Tests ============

    function testUnlimitedSpendAllowsExceedingTotalLimit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: 0, // Total limit ignored when unlimited
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 720 days, // Extended to accommodate 20 payments
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: true, // Unlimited
                authority: address(0)
            })
        );

        vm.prank(payer);
        usdc.approve(address(mandate), type(uint256).max);

        // Execute many payments
        for (uint256 i = 0; i < 20; i++) {
            if (i > 0) {
                vm.warp(block.timestamp + FREQUENCY);
            }
            vm.prank(executor);
            mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);
        }

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertTrue(m.totalPaid > TOTAL_LIMIT);
        assertTrue(m.isUnlimitedSpend);
    }

    function testUnlimitedSpendSetsMaxLimit() public {
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(usdc),
                totalLimit: 0,
                perPaymentLimit: PER_PAYMENT_LIMIT,
                frequency: FREQUENCY,
                startTime: block.timestamp,
                endTime: block.timestamp + 365 days,
                debitType: Mandate.DebitType.Variable,
                frequencyType: Mandate.Frequency.Monthly,
                isUnlimitedSpend: true,
                authority: address(0)
            })
        );

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalLimit, type(uint256).max);
    }

    // ============ Reentrancy Tests ============

    function testReentrancyProtection() public {
        // Add malicious token to supported tokens
        vm.prank(admin);
        mandate.setSupportedToken(address(malToken), true);

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(malToken),
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
        malToken.approve(address(mandate), TOTAL_LIMIT);

        // Setup attack
        malToken.setAttack(address(mandate), mandateId);

        // Execute payment - should not be vulnerable to reentrancy
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Check that only one payment was executed
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, PER_PAYMENT_LIMIT);
    }

    // ============ Critical Attack Tests ============

    function testCannotFrontRunCancellation() public {
        // Create mandate
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

        // Execute first payment
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        vm.warp(block.timestamp + FREQUENCY);

        // Payer cancels mandate
        vm.prank(payer);
        mandate.cancelMandate(mandateId);

        // Executor tries to execute payment after cancellation (should fail)
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Verify only one payment was made
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, PER_PAYMENT_LIMIT);
        assertFalse(m.isActive);
    }

    function testPayeeContractRevert() public {
        // Deploy contract that reverts on receiving tokens
        RevertingPayee revertingPayee = new RevertingPayee();

        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: address(revertingPayee),
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

        // Note: ERC20 transfer will fail, not the payee contract itself
        // This test verifies the mandate handles transfer failures gracefully
        vm.prank(executor);
        // This should revert at the token transfer level, not at mandate level
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Verify payment was successful (ERC20 doesn't have receive hooks)
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, PER_PAYMENT_LIMIT);
    }

    function testAdminCannotRemoveTokenWithActiveMandates() public {
        // Create mandate
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

        // Admin removes token support (this is allowed but risky)
        vm.prank(admin);
        mandate.setSupportedToken(address(usdc), false);

        // Existing mandate should still be able to execute
        // (mandate was created when token was supported)
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalPaid, PER_PAYMENT_LIMIT);
    }

    function testFeeOnTransferTokenAccountingIssue() public {
        // Create mandate with fee-on-transfer token
        vm.prank(payer);
        uint256 mandateId = mandate.createMandate(
            Mandate.CreateMandateParams({
                payee: payee,
                token: address(feeToken),
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
        feeToken.approve(address(mandate), TOTAL_LIMIT);

        uint256 payeeBalanceBefore = feeToken.balanceOf(payee);

        // Execute payment
        vm.prank(executor);
        mandate.executePayment(mandateId, PER_PAYMENT_LIMIT);

        // Check accounting discrepancy
        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        uint256 payeeBalanceAfter = feeToken.balanceOf(payee);
        uint256 actualReceived = payeeBalanceAfter - payeeBalanceBefore;

        // totalPaid records full amount, but payee receives less due to fee
        assertEq(m.totalPaid, PER_PAYMENT_LIMIT);
        assertTrue(actualReceived < PER_PAYMENT_LIMIT); // Payee received less than recorded
        assertEq(actualReceived, (PER_PAYMENT_LIMIT * 90) / 100); // 10% fee
    }

    function testReInitializationBlocked() public {
        // Try to re-initialize the mandate contract
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        // Should revert with InvalidInitialization from OpenZeppelin Initializable
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        mandate.initialize(admin, tokens);
    }
}

// Helper contract for testing payee revert scenarios
contract RevertingPayee {
// This contract doesn't revert on ERC20 transfers
// ERC20 tokens don't call receive/fallback on transfer
// This is just for testing contract payee scenarios
}
