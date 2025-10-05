// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Mandate
 * @dev Recurring stablecoin payment contract with user-controlled mandates
 * @notice Allows users to set up automatic recurring payments with full control
 */
contract Mandate is AccessControl, Pausable {
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

    // State variables
    mapping(uint256 => MandateData) public mandates;
    mapping(address => uint256[]) public userMandates; // User's mandate IDs
    uint256 public nextMandateId;
    
    // Supported tokens
    mapping(address => bool) public supportedTokens;
    
    // Initialization flag for clones
    bool private initialized;

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

    event MandateCanceled(
        uint256 indexed mandateId,
        address indexed payer,
        uint256 timestamp
    );

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event TokenSupported(address indexed token, bool supported);

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
    error Mandate_AlreadyInitialized();

    modifier onlyOnce() {
        if (initialized) revert Mandate_AlreadyInitialized();
        initialized = true;
        _;
    }

    constructor() {
        // Disable initialization for the implementation contract
        initialized = true;
    }

    function initialize(
        address _admin,
        address[] memory _supportedTokens
    ) external onlyOnce {
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
        if (_payee == address(0) || _payee == msg.sender)
            revert Mandate_InvalidParameters();
        if (!supportedTokens[_token]) revert Mandate_UnsupportedToken();
        if (_totalLimit == 0 || _perPaymentLimit == 0)
            revert Mandate_InvalidParameters();
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

        userMandates[msg.sender].push(mandateId);

        emit MandateCreated(
            mandateId,
            msg.sender,
            _payee,
            _token,
            _totalLimit,
            _perPaymentLimit,
            _frequency,
            _startTime,
            _endTime
        );

        return mandateId;
    }

    /**
     * @dev Executes a payment according to mandate rules
     * @param _mandateId The mandate ID to execute
     * @param _amount Amount to pay (must be <= perPaymentLimit)
     */
    function executePayment(
        uint256 _mandateId,
        uint256 _amount
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isActive) revert Mandate_MandateNotActive();
        if (block.timestamp > mandate.endTime) revert Mandate_MandateExpired();
        if (block.timestamp < mandate.startTime) revert Mandate_PaymentTooEarly();

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

        // Update mandate state
        mandate.totalPaid += _amount;
        mandate.lastPaymentTime = block.timestamp;

        // Execute transfer
        token.safeTransferFrom(mandate.payer, mandate.payee, _amount);

        emit PaymentExecuted(
            _mandateId,
            mandate.payer,
            mandate.payee,
            mandate.token,
            _amount,
            block.timestamp
        );
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
    function canExecutePayment(
        uint256 _mandateId,
        uint256 _amount
    ) external view returns (bool canExecute, string memory reason) {
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
        if (
            mandate.lastPaymentTime > 0 &&
            block.timestamp < mandate.lastPaymentTime + mandate.frequency
        ) {
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
    function getMandate(
        uint256 _mandateId
    ) external view returns (MandateData memory) {
        if (mandates[_mandateId].payer == address(0)) revert Mandate_InvalidMandateId();
        return mandates[_mandateId];
    }

    /**
     * @dev Gets all mandate IDs for a user
     * @param _user The user address
     * @return mandateIds Array of mandate IDs
     */
    function getUserMandates(
        address _user
    ) external view returns (uint256[] memory) {
        return userMandates[_user];
    }

    /**
     * @dev Gets active mandates for a user
     * @param _user The user address
     * @return activeMandateIds Array of active mandate IDs
     */
    function getUserActiveMandates(
        address _user
    ) external view returns (uint256[] memory) {
        uint256[] memory allMandates = userMandates[_user];
        uint256 activeCount = 0;

        // Count active mandates
        for (uint256 i = 0; i < allMandates.length; i++) {
            if (
                mandates[allMandates[i]].isActive &&
                block.timestamp <= mandates[allMandates[i]].endTime
            ) {
                activeCount++;
            }
        }

        // Create array of active mandate IDs
        uint256[] memory activeMandates = new uint256[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allMandates.length; i++) {
            if (
                mandates[allMandates[i]].isActive &&
                block.timestamp <= mandates[allMandates[i]].endTime
            ) {
                activeMandates[index] = allMandates[i];
                index++;
            }
        }

        return activeMandates;
    }

    // Admin functions

    /**
     * @dev Adds an executor
     * @param _executor Address to add as executor
     */
    function addExecutor(
        address _executor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(EXECUTOR_ROLE, _executor);
        emit ExecutorAdded(_executor);
    }

    /**
     * @dev Removes an executor
     * @param _executor Address to remove from executors
     */
    function removeExecutor(
        address _executor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(EXECUTOR_ROLE, _executor);
        emit ExecutorRemoved(_executor);
    }

    /**
     * @dev Sets token support status
     * @param _token Token address
     * @param _supported Whether token is supported
     */
    function setSupportedToken(
        address _token,
        bool _supported
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function emergencyCancelMandate(
        uint256 _mandateId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isActive) revert Mandate_MandateNotActive();

        mandate.isActive = false;

        emit MandateCanceled(_mandateId, mandate.payer, block.timestamp);
    }

    /**
     * @dev Returns the version of the contract
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}