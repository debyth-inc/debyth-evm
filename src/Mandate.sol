// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title Mandate
 * @dev Recurring stablecoin payment contract with user-controlled mandates
 * @notice Allows users to set up automatic recurring payments with full control
 */
contract Mandate is AccessControl, Pausable, Initializable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // Structs
    struct MandateData {
        address payer; // User who created the mandate
        address payee; // Who receives the payments
        address token; // USDC or USDT address
        uint256 totalLimit; // Maximum total amount that can be paid
        uint256 perPaymentLimit; // Maximum amount per payment
        uint256 frequency; // Payment frequency in seconds
        uint256 startTime; // When payments can start
        uint256 endTime; // When mandate expires
        uint256 totalPaid; // Total amount paid so far
        uint256 lastPaymentTime; // Timestamp of last payment
        bool isActive; // Whether mandate is active
        uint256 createdAt; // Creation timestamp
    }

    struct ApprovalSettings {
        uint256 lowAllowanceThreshold; // When to emit warning (number of payments)
        uint256 criticalThreshold; // When to auto-pause (number of payments)
        bool autoPauseEnabled; // User preference for auto-pause
        bool isPausedBySystem; // System auto-pause status
    }

    // State variables
    mapping(uint256 => MandateData) public mandates;
    mapping(uint256 => ApprovalSettings) public approvalSettings;
    mapping(address => uint256[]) public userMandates; // User's mandate IDs
    uint256 public nextMandateId;

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Events
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

    event MandateCanceled(uint256 indexed mandateId, address indexed payer, uint256 timestamp);

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event TokenSupported(address indexed token, bool supported);

    // Approval Health Events
    event ApprovalLowWarning(
        uint256 indexed mandateId, uint256 remainingAllowance, uint256 paymentsRemaining, uint256 recommendedTopUp
    );
    event ApprovalCritical(uint256 indexed mandateId, uint256 remainingAllowance, uint256 recommendedTopUp);
    event MandateAutoPaused(uint256 indexed mandateId, string reason);
    event ApprovalTopUpRequested(uint256 indexed mandateId, uint256 recommendedAmount, uint256 forPayments);
    event MandateUnpaused(uint256 indexed mandateId, address indexed user);
    event ApprovalThresholdsUpdated(uint256 indexed mandateId, uint256 lowThreshold, uint256 criticalThreshold);

    // Custom errors
    error Mandate_InvalidMandateId();
    error Mandate_UnauthorizedCaller();
    error Mandate_MandateNotActive();
    error Mandate_PaymentTooEarly();
    error Mandate_PaymentExceedsLimit();
    error Mandate_InsufficientAllowance();
    error Mandate_InsufficientBalance();
    error Mandate_UnsupportedToken();
    error Mandate_InvalidParameters();
    error Mandate_MandateExpired();
    error Mandate_SystemPaused();
    error Mandate_NotSystemPaused();

    constructor() {
        _disableInitializers();
    }

    function initialize(address _admin, address[] memory _supportedTokens) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        // Add supported tokens
        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            supportedTokens[_supportedTokens[i]] = true;
            emit TokenSupported(_supportedTokens[i], true);
        }

        nextMandateId = 1;
    }

    /**
     * @dev Creates a new payment mandate
     * @param _payee Address to receive payments
     * @param _token Token address (USDC/USDT)
     * @param _totalLimit Maximum total amount that can be paid
     * @param _perPaymentLimit Maximum amount per payment
     * @param _frequency Payment frequency in seconds
     * @param _startTime When payments can start
     * @param _endTime When mandate expires
     */
    function createMandate(
        address _payee,
        address _token,
        uint256 _totalLimit,
        uint256 _perPaymentLimit,
        uint256 _frequency,
        uint256 _startTime,
        uint256 _endTime
    ) external whenNotPaused returns (uint256) {
        if (_payee == address(0) || _payee == msg.sender) {
            revert Mandate_InvalidParameters();
        }
        if (!supportedTokens[_token]) revert Mandate_UnsupportedToken();
        if (_totalLimit == 0 || _perPaymentLimit == 0) {
            revert Mandate_InvalidParameters();
        }
        if (_perPaymentLimit > _totalLimit) revert Mandate_InvalidParameters();
        if (_frequency == 0) revert Mandate_InvalidParameters();
        if (_startTime < block.timestamp) revert Mandate_InvalidParameters();
        if (_endTime <= _startTime) revert Mandate_InvalidParameters();

        uint256 mandateId = nextMandateId++;

        mandates[mandateId] = MandateData({
            payer: msg.sender,
            payee: _payee,
            token: _token,
            totalLimit: _totalLimit,
            perPaymentLimit: _perPaymentLimit,
            frequency: _frequency,
            startTime: _startTime,
            endTime: _endTime,
            totalPaid: 0,
            lastPaymentTime: 0,
            isActive: true,
            createdAt: block.timestamp
        });

        approvalSettings[mandateId] = ApprovalSettings({
            lowAllowanceThreshold: 3, // Default: warn when 3 payments remaining
            criticalThreshold: 1, // Default: pause when 1 payment remaining
            autoPauseEnabled: true, // Default: auto-pause enabled
            isPausedBySystem: false
        });

        userMandates[msg.sender].push(mandateId);

        emit MandateCreated(
            mandateId, msg.sender, _payee, _token, _totalLimit, _perPaymentLimit, _frequency, _startTime, _endTime
        );

        return mandateId;
    }

    /**
     * @dev Executes a payment according to mandate rules
     * @param _mandateId The mandate ID to execute
     * @param _amount Amount to pay (must be <= perPaymentLimit)
     */
    function executePayment(uint256 _mandateId, uint256 _amount) external onlyRole(EXECUTOR_ROLE) whenNotPaused {
        _validatePayment(_mandateId, _amount);
        _processPayment(_mandateId, _amount);
        _checkApprovalHealth(_mandateId);
    }

    function _validatePayment(uint256 _mandateId, uint256 _amount) internal view {
        MandateData storage mandate = mandates[_mandateId];
        ApprovalSettings storage settings = approvalSettings[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isActive) revert Mandate_MandateNotActive();
        if (settings.isPausedBySystem) revert Mandate_SystemPaused();
        if (block.timestamp > mandate.endTime) revert Mandate_MandateExpired();
        if (block.timestamp < mandate.startTime) {
            revert Mandate_PaymentTooEarly();
        }

        // Check frequency constraint
        if (mandate.lastPaymentTime > 0) {
            if (block.timestamp < mandate.lastPaymentTime + mandate.frequency) {
                revert Mandate_PaymentTooEarly();
            }
        }

        // Check amount limits
        if (_amount == 0 || _amount > mandate.perPaymentLimit) {
            revert Mandate_PaymentExceedsLimit();
        }
        if (mandate.totalPaid + _amount > mandate.totalLimit) {
            revert Mandate_PaymentExceedsLimit();
        }

        IERC20 token = IERC20(mandate.token);

        // Check allowance and balance
        uint256 allowance = token.allowance(mandate.payer, address(this));
        if (allowance < _amount) revert Mandate_InsufficientAllowance();

        uint256 balance = token.balanceOf(mandate.payer);
        if (balance < _amount) revert Mandate_InsufficientBalance();
    }

    function _processPayment(uint256 _mandateId, uint256 _amount) internal {
        MandateData storage mandate = mandates[_mandateId];
        IERC20 token = IERC20(mandate.token);

        // Update mandate state
        mandate.totalPaid += _amount;
        mandate.lastPaymentTime = block.timestamp;

        // Execute transfer
        token.safeTransferFrom(mandate.payer, mandate.payee, _amount);

        emit PaymentExecuted(_mandateId, mandate.payer, mandate.payee, mandate.token, _amount, block.timestamp);
    }

    /**
     * @dev Cancels a mandate (only by the payer)
     * @param _mandateId The mandate ID to cancel
     */
    function cancelMandate(uint256 _mandateId) external {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.payer != msg.sender) revert Mandate_UnauthorizedCaller();
        if (!mandate.isActive) revert Mandate_MandateNotActive();

        mandate.isActive = false;

        emit MandateCanceled(_mandateId, msg.sender, block.timestamp);
    }

    /**
     * @dev Checks if a payment can be executed
     * @param _mandateId The mandate ID to check
     * @param _amount Amount to check
     * @return canExecute Whether payment can be executed
     * @return reason Reason if payment cannot be executed
     */
    function canExecutePayment(uint256 _mandateId, uint256 _amount)
        external
        view
        returns (bool canExecute, string memory reason)
    {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) {
            return (false, "Invalid mandate ID");
        }
        if (!mandate.isActive) {
            return (false, "Mandate not active");
        }
        if (block.timestamp > mandate.endTime) {
            return (false, "Mandate expired");
        }
        if (block.timestamp < mandate.startTime) {
            return (false, "Payment too early - start time not reached");
        }
        if (mandate.lastPaymentTime > 0 && block.timestamp < mandate.lastPaymentTime + mandate.frequency) {
            return (false, "Payment too early - frequency constraint");
        }
        if (_amount == 0 || _amount > mandate.perPaymentLimit) {
            return (false, "Amount exceeds per-payment limit");
        }
        if (mandate.totalPaid + _amount > mandate.totalLimit) {
            return (false, "Amount exceeds total limit");
        }

        IERC20 token = IERC20(mandate.token);
        uint256 allowance = token.allowance(mandate.payer, address(this));
        if (allowance < _amount) {
            return (false, "Insufficient allowance");
        }

        uint256 balance = token.balanceOf(mandate.payer);
        if (balance < _amount) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    /**
     * @dev Gets mandate details
     * @param _mandateId The mandate ID
     * @return mandate The mandate struct
     */
    function getMandate(uint256 _mandateId) external view returns (MandateData memory) {
        if (mandates[_mandateId].payer == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        return mandates[_mandateId];
    }

    /**
     * @dev Gets all mandate IDs for a user
     * @param _user The user address
     * @return mandateIds Array of mandate IDs
     */
    function getUserMandates(address _user) external view returns (uint256[] memory) {
        return userMandates[_user];
    }

    /**
     * @dev Gets active mandates for a user
     * @param _user The user address
     * @return activeMandateIds Array of active mandate IDs
     */
    function getUserActiveMandates(address _user) external view returns (uint256[] memory) {
        uint256[] memory allMandates = userMandates[_user];
        uint256 activeCount = 0;

        // Count active mandates
        for (uint256 i = 0; i < allMandates.length; i++) {
            if (mandates[allMandates[i]].isActive && block.timestamp <= mandates[allMandates[i]].endTime) {
                activeCount++;
            }
        }

        // Create array of active mandate IDs
        uint256[] memory activeMandates = new uint256[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allMandates.length; i++) {
            if (mandates[allMandates[i]].isActive && block.timestamp <= mandates[allMandates[i]].endTime) {
                activeMandates[index] = allMandates[i];
                index++;
            }
        }

        return activeMandates;
    }

    // Approval Health Management

    /**
     * @dev Checks approval health and emits warnings/auto-pauses if needed
     * @param _mandateId The mandate ID to check
     */
    function _checkApprovalHealth(uint256 _mandateId) internal {
        MandateData storage mandate = mandates[_mandateId];
        ApprovalSettings storage settings = approvalSettings[_mandateId];

        IERC20 token = IERC20(mandate.token);
        uint256 currentAllowance = token.allowance(mandate.payer, address(this));
        uint256 paymentsRemaining = currentAllowance / mandate.perPaymentLimit;

        // Check critical threshold first
        if (paymentsRemaining <= settings.criticalThreshold && settings.autoPauseEnabled) {
            settings.isPausedBySystem = true;
            uint256 recommendedTopUp = calculateRecommendedTopUp(_mandateId, 6);

            emit ApprovalCritical(_mandateId, currentAllowance, recommendedTopUp);
            emit MandateAutoPaused(_mandateId, "Insufficient allowance for future payments");
        }
        // Check low threshold
        else if (paymentsRemaining <= settings.lowAllowanceThreshold) {
            uint256 recommendedTopUp = calculateRecommendedTopUp(_mandateId, 6);

            emit ApprovalLowWarning(_mandateId, currentAllowance, paymentsRemaining, recommendedTopUp);
            emit ApprovalTopUpRequested(_mandateId, recommendedTopUp, 6);
        }
    }

    /**
     * @dev Manually check approval health for a mandate
     * @param _mandateId The mandate ID to check
     */
    function checkApprovalHealth(uint256 _mandateId) external {
        if (mandates[_mandateId].payer == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        _checkApprovalHealth(_mandateId);
    }

    /**
     * @dev Calculate recommended top-up amount for upcoming payments
     * @param _mandateId The mandate ID
     * @param _paymentsAhead Number of payments to calculate for
     * @return recommendedAmount The recommended approval amount
     */
    function calculateRecommendedTopUp(uint256 _mandateId, uint256 _paymentsAhead)
        public
        view
        returns (uint256 recommendedAmount)
    {
        MandateData storage mandate = mandates[_mandateId];

        // Base calculation: payments ahead * per payment limit
        uint256 baseAmount = _paymentsAhead * mandate.perPaymentLimit;

        // Add 10% buffer for gas variations and timing
        uint256 buffer = baseAmount / 10;

        // Consider remaining mandate duration
        uint256 remainingTime = mandate.endTime > block.timestamp ? mandate.endTime - block.timestamp : 0;
        uint256 maxPossiblePayments = remainingTime / mandate.frequency;

        // Don't recommend more than what's needed for remaining duration
        uint256 maxNeeded = maxPossiblePayments * mandate.perPaymentLimit;
        uint256 remainingLimit = mandate.totalLimit - mandate.totalPaid;

        // Take the minimum of calculated amount, max possible payments, and remaining limit
        recommendedAmount = baseAmount + buffer;
        if (recommendedAmount > maxNeeded) recommendedAmount = maxNeeded;
        if (recommendedAmount > remainingLimit) {
            recommendedAmount = remainingLimit;
        }

        return recommendedAmount;
    }

    /**
     * @dev Set approval thresholds for a mandate
     * @param _mandateId The mandate ID
     * @param _lowThreshold Number of payments remaining to trigger warning
     * @param _criticalThreshold Number of payments remaining to trigger auto-pause
     */
    function setApprovalThresholds(uint256 _mandateId, uint256 _lowThreshold, uint256 _criticalThreshold) external {
        MandateData storage mandate = mandates[_mandateId];
        ApprovalSettings storage settings = approvalSettings[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.payer != msg.sender) revert Mandate_UnauthorizedCaller();
        if (_criticalThreshold >= _lowThreshold) {
            revert Mandate_InvalidParameters();
        }

        settings.lowAllowanceThreshold = _lowThreshold;
        settings.criticalThreshold = _criticalThreshold;

        emit ApprovalThresholdsUpdated(_mandateId, _lowThreshold, _criticalThreshold);
    }

    /**
     * @dev Enable or disable auto-pause for a mandate
     * @param _mandateId The mandate ID
     * @param _enabled Whether to enable auto-pause
     */
    function setAutoPause(uint256 _mandateId, bool _enabled) external {
        MandateData storage mandate = mandates[_mandateId];
        ApprovalSettings storage settings = approvalSettings[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.payer != msg.sender) revert Mandate_UnauthorizedCaller();

        settings.autoPauseEnabled = _enabled;
    }

    /**
     * @dev Unpause a system-paused mandate
     * @param _mandateId The mandate ID to unpause
     */
    function unpauseMandate(uint256 _mandateId) external {
        MandateData storage mandate = mandates[_mandateId];
        ApprovalSettings storage settings = approvalSettings[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.payer != msg.sender) revert Mandate_UnauthorizedCaller();
        if (!settings.isPausedBySystem) revert Mandate_NotSystemPaused();

        settings.isPausedBySystem = false;

        emit MandateUnpaused(_mandateId, msg.sender);
    }

    /**
     * @dev Get approval health status for a mandate
     * @param _mandateId The mandate ID
     * @return currentAllowance Current token allowance
     * @return paymentsRemaining Number of payments possible with current allowance
     * @return recommendedTopUp Recommended top-up amount
     * @return isHealthy Whether approval is above low threshold
     */
    function getApprovalHealth(uint256 _mandateId)
        external
        view
        returns (uint256 currentAllowance, uint256 paymentsRemaining, uint256 recommendedTopUp, bool isHealthy)
    {
        MandateData storage mandate = mandates[_mandateId];
        ApprovalSettings storage settings = approvalSettings[_mandateId];
        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();

        IERC20 token = IERC20(mandate.token);
        currentAllowance = token.allowance(mandate.payer, address(this));
        paymentsRemaining = currentAllowance / mandate.perPaymentLimit;
        recommendedTopUp = calculateRecommendedTopUp(_mandateId, 6);
        isHealthy = paymentsRemaining > settings.lowAllowanceThreshold;
    }

    // Admin functions

    /**
     * @dev Adds an executor
     * @param _executor Address to add as executor
     */
    function addExecutor(address _executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(EXECUTOR_ROLE, _executor);
        emit ExecutorAdded(_executor);
    }

    /**
     * @dev Removes an executor
     * @param _executor Address to remove from executors
     */
    function removeExecutor(address _executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(EXECUTOR_ROLE, _executor);
        emit ExecutorRemoved(_executor);
    }

    /**
     * @dev Sets token support status
     * @param _token Token address
     * @param _supported Whether token is supported
     */
    function setSupportedToken(address _token, bool _supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedTokens[_token] = _supported;
        emit TokenSupported(_token, _supported);
    }

    /**
     * @dev Pauses the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Emergency cancel mandate (admin only)
     * @param _mandateId The mandate ID to cancel
     */
    function emergencyCancelMandate(uint256 _mandateId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isActive) revert Mandate_MandateNotActive();

        mandate.isActive = false;

        emit MandateCanceled(_mandateId, mandate.payer, block.timestamp);
    }

    function getApprovalSettings(uint256 _mandateId) external view returns (ApprovalSettings memory) {
        if (mandates[_mandateId].payer == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        return approvalSettings[_mandateId];
    }
}
