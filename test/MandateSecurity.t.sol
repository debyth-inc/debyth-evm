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

    uint256 constant TOTAL_LIMIT = 1000e6;
    uint256 constant PER_EXECUTION_LIMIT = 100e6;
    uint256 constant MIN_INTERVAL = 30 days;

    function computePolicyHash(
        Mandate.ChargeType chargeType,
        Mandate.Frequency frequency,
        uint256 minIntervalSeconds,
        uint256 perExecutionLimit,
        uint256 totalLimit,
        uint256 startAt,
        uint256 endAt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            chargeType, frequency, minIntervalSeconds, perExecutionLimit, totalLimit, startAt, endAt
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
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            PER_EXECUTION_LIMIT,
            TOTAL_LIMIT,
            startAt,
            endAt
        );
        vm.prank(executor);
        mandate.createMandate(
            sender,
            mandateId,
            recipient,
            address(usdc),
            TOTAL_LIMIT,
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE,
            Mandate.Frequency.MONTHLY,
            MIN_INTERVAL,
            startAt,
            endAt,
            empty,
            empty,
            policyHash
        );
    }

    function _approveMandate(bytes32 mandateId) internal {
        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

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
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), address(0), address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );
    }

    function testCannotCreateMandateWithZeroPerExecutionLimit() public {
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            0, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            TOTAL_LIMIT, 0,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );
    }

    function testCannotCreateMandateWithZeroMinInterval() public {
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, 0,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, 0,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );
    }

    function testCannotCreateMandateWithEndTimeBeforeStart() public {
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp - 1
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_InvalidParameters.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp - 1, empty, empty, policyHash
        );
    }

    function testCannotCreateMandateWithUnsupportedToken() public {
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        vm.prank(executor);
        vm.expectRevert(Mandate.Mandate_UnsupportedToken.selector);
        mandate.createMandate(
            sender, generateMandateId(), recipient, makeAddr("unsupported"),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
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
        usdc.approve(address(mandate), TOTAL_LIMIT);

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

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mandate.createMandate(
            sender, generateMandateId(), recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
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
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.FIXED, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.FIXED, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), TOTAL_LIMIT);

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

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(malToken),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );

        vm.prank(sender);
        malToken.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        malToken.setAttack(address(mandate), mandateId);

        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalExecuted, PER_EXECUTION_LIMIT);
    }

    // ============ Fee-on-Transfer Tests ============

    function testFeeOnTransferTokenAccounting() public {
        vm.prank(admin);
        mandate.setSupportedToken(address(feeToken), true);

        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, TOTAL_LIMIT, block.timestamp, block.timestamp + 365 days
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(feeToken),
            TOTAL_LIMIT, PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );

        vm.prank(sender);
        feeToken.approve(address(mandate), TOTAL_LIMIT);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        uint256 recipientBalanceBefore = feeToken.balanceOf(recipient);

        vm.prank(executor);
        mandate.executeMandate(mandateId, PER_EXECUTION_LIMIT, 1);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        uint256 recipientBalanceAfter = feeToken.balanceOf(recipient);
        uint256 actualReceived = recipientBalanceAfter - recipientBalanceBefore;

        assertEq(m.totalExecuted, PER_EXECUTION_LIMIT);
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
        address[] memory empty;
        bytes32 policyHash = computePolicyHash(
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            PER_EXECUTION_LIMIT, 0, block.timestamp, block.timestamp + 365 days
        );

        bytes32 mandateId = generateMandateId();
        vm.prank(executor);
        mandate.createMandate(
            sender, mandateId, recipient, address(usdc),
            0, // totalLimit = 0 means unlimited
            PER_EXECUTION_LIMIT,
            Mandate.ChargeType.VARIABLE, Mandate.Frequency.MONTHLY, MIN_INTERVAL,
            block.timestamp, block.timestamp + 365 days, empty, empty, policyHash
        );

        vm.prank(sender);
        usdc.approve(address(mandate), type(uint256).max);

        vm.prank(sender);
        mandate.approveMandate(mandateId);

        Mandate.MandateData memory m = mandate.getMandate(mandateId);
        assertEq(m.totalLimit, type(uint256).max);
    }
}
