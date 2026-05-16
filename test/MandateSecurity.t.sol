// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Mandate} from "../src/Mandate.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MaliciousToken is ERC20 {
    address public mandateContract;
    bytes32 public attackMandateId;
    bool public attackInitiated;

    constructor() ERC20("Malicious", "MAL") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function setAttack(address _mandate, bytes32 _mandateId) external {
        mandateContract = _mandate;
        attackMandateId = _mandateId;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!attackInitiated && mandateContract != address(0)) {
            attackInitiated = true;
            try Mandate(mandateContract).executeMandate(attackMandateId, amount, 1) {} catch {}
        }
        return super.transferFrom(from, to, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferToken is ERC20 {
    uint256 public transferFeePercent = 10;

    constructor() ERC20("FeeToken", "FEE") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * transferFeePercent) / 100;
        uint256 amountAfterFee = amount - fee;
        _transfer(from, to, amountAfterFee);
        if (fee > 0) {
            _transfer(from, address(0xdead), fee);
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

    uint256 public mandateIdCounter;

    function generateMandateId() internal returns (bytes32) {
        return keccak256(abi.encodePacked("mandate-", mandateIdCounter++));
    }

    address public admin = makeAddr("admin");
    address public executor = makeAddr("executor");
    address public sender = makeAddr("sender");
    address public recipient = makeAddr("recipient");
    address public unauthorized = makeAddr("unauthorized");

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
        malToken = new MaliciousToken();
        feeToken = new FeeOnTransferToken();

        Mandate implementation = new Mandate();

        address[] memory supportedTokens = new address[](3);
        supportedTokens[0] = address(usdc);
        supportedTokens[1] = address(malToken);
        supportedTokens[2] = address(feeToken);

        vm.prank(admin);
        bytes memory initData = abi.encodeWithSelector(Mandate.initialize.selector, admin, supportedTokens, executor);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, initData);
        mandate = Mandate(address(proxy));

        usdc.mint(sender, 10000e6);
        malToken.mint(sender, 10000e6);
        feeToken.mint(sender, 10000e6);
        mandateIdCounter = 0;
    }

    function _createMandate(
        bytes32 mandateId,
        uint256 startAt,
        uint256 endAt
    ) internal {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            0,
            0
        );
        vm.prank(executor);
        mandate.createMandate(
            sender,
            mandateId,
            recipient,
            address(usdc),
            AUTHORIZED_LIMIT,
            Mandate.ChargeType.VARIABLE,
            startAt,
            endAt,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            0,
            0,
            policyHash
        );
    }

    function _approveMandate(bytes32 mandateId) internal {
        vm.prank(sender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);
    }

    // ============ Authorization Tests ============

    function testUnauthorizedExecutorCannotExecutePayment() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testUnauthorizedUserCannotCancelMandate() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(unauthorized);
        vm.expectRevert(Mandate.Mandate_UnauthorizedCaller.selector);
        mandate.cancelMandate(mandateId);
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
        mandate.pauseContract();
    }

    function testNonAdminCannotUnpauseContract() public {
        vm.prank(admin);
        mandate.pauseContract();

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.unpauseContract();
    }

    function testNonAdminCannotEmergencyCancel() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.emergencyCancelMandate(mandateId);
    }

    function testAdminCanEmergencyCancel() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(admin);
        mandate.emergencyCancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.CANCELLED));
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

    function testNonPauserCannotPauseExecution() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.pauseExecution();
    }

    function testNonPauserCannotResumeExecution() public {
        vm.prank(admin);
        mandate.pauseExecution();

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.resumeExecution();
    }

    // ============ Edge Case Tests ============

    function testCannotCreateMandateWithZeroAddress() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), address(0), address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function testCannotCreateMandateWithZeroPerExecutionLimit() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            0, 0, 0
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, 0,
            0, 0, policyHash
        );
    }

    function testCannotCreateMandateWithZeroMinInterval() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, 0,
            PER_EXECUTION_LIMIT, 0, 0
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, 0, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function testCannotCreateMandateWithEndTimeBeforeStart() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp - 1,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function testCannotCreateMandateWithUnsupportedToken() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_UnsupportedToken.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, makeAddr("unsupported"),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function testCannotExecuteOnInvalidMandateId() public {
        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.executeMandate(bytes32(uint256(999)), 50e6, 1);
    }

    function testCannotExecuteOnInactiveMandate() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_MandateNotActive.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testCannotExecuteWithZeroAmount() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);

        vm.prank(sender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidAmountForVariableDebit.selector);
        mandate.executeMandate(mandateId, 0, 1);
    }

    function testCannotExecuteExceedingPerExecutionLimit() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidAmountForVariableDebit.selector);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT + 1, 1);
    }

    function testCancelAlreadyCancelledReturnsWithoutError() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        vm.prank(sender);
        mandate.cancelMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.CANCELLED));
    }

    function testCannotCreateMandateWhenContractPaused() public {
        vm.prank(admin);
        mandate.pauseContract();

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );
    }

    function testCannotExecutePaymentWhenContractPaused() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(admin);
        mandate.pauseContract();

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testGetMandateRevertForInvalidId() public {
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.getMandate(bytes32(uint256(999)));
    }

    function testGetPolicyRevertForInvalidId() public {
        vm.expectRevert(Mandate.Mandate_InvalidMandateId.selector);
        mandate.getPolicy(bytes32(uint256(999)));
    }

    // ============ Debit Type Tests ============

    function testFixedDebitRequiresExactAmount() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.FIXED,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidAmountForFixedDebit.selector);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT - 1, 1);

        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 1);
    }

    // ============ Nonce Tests ============

    function testCannotReuseNonce() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 1);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidNonce.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testNonceMustBeIncreasing() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, 50e6, 2);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidNonce.selector);
        mandate.executeMandate(mandateId, 50e6, 1);
    }

    function testNonceCannotBeZero() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidNonce.selector);
        mandate.executeMandate(mandateId, 50e6, 0);
    }

    // ============ Reentrancy Tests ============

    function testReentrancyProtection() public {
        vm.prank(admin);
        mandate.setSupportedToken(address(malToken), true);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(malToken),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(sender);
        malToken.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        malToken.setAttack(address(mandate), mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.executionState.totalExecuted, PER_EXECUTION_LIMIT);
    }

    // ============ Fee-on-Transfer Tests ============

    function testFeeOnTransferTokenAccounting() public {
        vm.prank(admin);
        mandate.setSupportedToken(address(feeToken), true);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(feeToken),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(sender);
        feeToken.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        uint256 recipientBalanceBefore = feeToken.balanceOf(recipient);

        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        uint256 recipientBalanceAfter = feeToken.balanceOf(recipient);
        uint256 actualReceived = recipientBalanceAfter - recipientBalanceBefore;

        assertEq(m.executionState.totalExecuted, PER_EXECUTION_LIMIT);
        assertTrue(actualReceived < PER_EXECUTION_LIMIT);
    }

    // ============ Initialization Tests ============

    function testReInitializationBlocked() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        mandate.initialize(admin, tokens, executor);
    }

    // ============ Unlimited Allowance Tests ============

    function testUnlimitedMandateApproval() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            0, // authorizedLimit = 0 means unlimited
            Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), type(uint256).max);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.authorizedLimit, type(uint256).max);
    }

    // ============ Policy Exceeds Authority Tests ============

    function testPolicyCannotExceedAuthority() public {
        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            2000e6, 0, 0 // perExecutionLimit > authorizedLimit
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_PolicyExceedsAuthority.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            1000e6, // authorizedLimit
            Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, 2000e6, // perExecutionLimit > authorizedLimit
            0, 0, policyHash
        );
    }

    // ============ Toggle Mandate State Access Control ============

    function testNonExecutorCannotToggleMandateState() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(unauthorized);
        vm.expectRevert();
        mandate.toggleMandateState(mandateId);
    }

    function testExecutorCanToggleMandateState() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        vm.prank(executor);
        mandate.toggleMandateState(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(uint256(m.status), uint256(Mandate.MandateStatus.PAUSED));
    }

    // ============ Modify Mandate Signature Tests ============

    function testModifyMandateWithValidSignature() public {
        bytes32 newPolicyHash = keccak256("new-policy");
        uint256 signatureNonce = 1;
        uint256 senderPrivateKey = 1;
        address expectedSender = vm.addr(senderPrivateKey);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );
        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            expectedSender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(expectedSender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(expectedSender);
        mandate.approveMandate(mandateId);

        bytes32 messageHash = keccak256(abi.encode(mandateId, newPolicyHash, signatureNonce, block.chainid));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(senderPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(expectedSender);
        mandate.modifyMandate(mandateId, newPolicyHash, signatureNonce, signature);

        Mandate.Policy memory p = mandate.getPolicy(mandateId);
        assertEq(p.policyHash, newPolicyHash);
    }

    function testModifyMandateWithInvalidSignature() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);
        _approveMandate(mandateId);

        bytes32 newPolicyHash = keccak256("new-policy");
        uint256 signatureNonce = 1;
        uint256 wrongPrivateKey = 2;

        bytes32 messageHash = keccak256(abi.encode(mandateId, newPolicyHash, signatureNonce, block.chainid));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(sender);
        vm.expectRevert(Mandate.Mandate_InvalidSignature.selector);
        mandate.modifyMandate(mandateId, newPolicyHash, signatureNonce, signature);
    }

    function testModifyMandateReplayProtection() public {
        uint256 senderPrivateKey = 1;
        address expectedSender = vm.addr(senderPrivateKey);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );
        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            expectedSender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(expectedSender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(expectedSender);
        mandate.approveMandate(mandateId);

        bytes32 newPolicyHash = keccak256("new-policy");
        uint256 signatureNonce = 1;

        bytes32 messageHash = keccak256(abi.encode(mandateId, newPolicyHash, signatureNonce, block.chainid));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(senderPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(expectedSender);
        mandate.modifyMandate(mandateId, newPolicyHash, signatureNonce, signature);

        vm.prank(expectedSender);
        vm.expectRevert(Mandate.Mandate_SignatureNonceUsed.selector);
        mandate.modifyMandate(mandateId, newPolicyHash, signatureNonce, signature);
    }

    function testModifyMandateRelayerPattern() public {
        uint256 senderPrivateKey = 1;
        address expectedSender = vm.addr(senderPrivateKey);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );
        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            expectedSender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(expectedSender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(expectedSender);
        mandate.approveMandate(mandateId);

        bytes32 newPolicyHash = keccak256("new-policy");
        uint256 signatureNonce = 1;

        bytes32 messageHash = keccak256(abi.encode(mandateId, newPolicyHash, signatureNonce, block.chainid));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(senderPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(unauthorized);
        mandate.modifyMandate(mandateId, newPolicyHash, signatureNonce, signature);

        Mandate.Policy memory p = mandate.getPolicy(mandateId);
        assertEq(p.policyHash, newPolicyHash);
    }

    function testModifyMandateSignatureCrossChainReplayProtection() public {
        uint256 senderPrivateKey = 1;
        address expectedSender = vm.addr(senderPrivateKey);

        bytes32 policyHash = computePolicyHash(
            Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, 0
        );
        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            expectedSender, mandateId, recipient, address(usdc),
            AUTHORIZED_LIMIT, Mandate.ChargeType.VARIABLE,
            block.timestamp, block.timestamp + 365 days,
            Mandate.Frequency.MONTHLY, MIN_INTERVAL, PER_EXECUTION_LIMIT,
            0, 0, policyHash
        );

        vm.prank(expectedSender);
        usdc.approve(address(mandate), AUTHORIZED_LIMIT);

        vm.prank(expectedSender);
        mandate.approveMandate(mandateId);

        bytes32 newPolicyHash = keccak256("new-policy");
        uint256 signatureNonce = 1;

        bytes32 messageHash = keccak256(abi.encode(mandateId, newPolicyHash, signatureNonce, 99999));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(senderPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(expectedSender);
        vm.expectRevert(Mandate.Mandate_InvalidSignature.selector);
        mandate.modifyMandate(mandateId, newPolicyHash, signatureNonce, signature);
    }

    // ============ Emergency Cancel PENDING Mandate ============

    function testAdminCanEmergencyCancelPendingMandate() public {
        bytes32 mandateId = generateMandateId();
        _createMandate(mandateId, block.timestamp, block.timestamp + 365 days);

        Mandate.MandateData memory mBefore = mandate.getMandate(mandateId);
        assertEq(uint256(mBefore.status), uint256(Mandate.MandateStatus.PENDING));

        vm.prank(admin);
        mandate.emergencyCancelMandate(mandateId);

        Mandate.MandateData memory mAfter = mandate.getMandate(mandateId);
        assertEq(uint256(mAfter.status), uint256(Mandate.MandateStatus.CANCELLED));
    }
}
