// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title Mandate
 * @dev Recurring stablecoin payment contract with user-controlled mandates
 * @notice Allows users to set up automatic recurring payments with full control
 */
contract Mandate is AccessControl, Pausable, Initializable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // Constants
    uint256 public constant UNLIMITED_ALLOWANCE = type(uint256).max;

    // Enums
    enum DebitType {
        Fixed, // Must debit exact amountPerDebit
        Variable // Can debit any amount up to amountPerDebit

    }

    enum Frequency {
        Daily, // Payment occurs daily
        Weekly, // Payment occurs weekly
        Monthly, // Payment occurs monthly
        Annually // Payment occurs annually

    }

    // Structs
    struct CreateMandateParams {
        address payee;
        address token;
        uint256 totalLimit;
        uint256 amountPerDebit;
        uint256 frequency;
        uint256 startTime;
        uint256 endTime;
        DebitType debitType;
        Frequency frequencyType;
        bool isUnlimitedSpend;
        address authority;
    }

    struct MandateData {
        address payer;
        address payee;
        address token;
        uint256 totalLimit;
        uint256 amountPerDebit;
        uint256 frequency;
        uint256 startTime;
        uint256 endTime;
        uint256 totalPaid;
        uint256 lastPaymentTime;
        bool isActive;
        bool isApproved;
        uint256 createdAt;
        DebitType debitType;
        Frequency frequencyType;
        bool isUnlimitedSpend;
        address authority;
    }

    mapping(bytes32 => MandateData) public mandates;
    mapping(address => bool) public supportedTokens;

    // Events
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
        DebitType debitType,
        Frequency frequencyType
    );

    event MandateExecuted(
        bytes32 indexed mandateId,
        address indexed payer,
        address indexed payee,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    event MandateCanceled(bytes32 indexed mandateId, address indexed payer, uint256 timestamp);

    event MandateApproved(bytes32 indexed mandateId, address indexed user, uint256 timestamp);

    event MandateStateToggled(bytes32 indexed mandateId, address indexed caller, bool newState, uint256 timestamp);

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event TokenSupported(address indexed token, bool supported);

    // Custom errors
    error Mandate_InvalidMandateId();
    error Mandate_UnauthorizedCaller();
    error Mandate_MandateNotActive();
    error Mandate_ExecutionTooEarly();
    error Mandate_ExecutionExceedsLimit();
    error Mandate_InsufficientAllowance();
    error Mandate_InsufficientBalance();
    error Mandate_UnsupportedToken();
    error Mandate_InvalidParameters();
    error Mandate_MandateExpired();
    error Mandate_InvalidAmountForFixedDebit();
    error Mandate_InvalidAmountForVariableDebit();
    error Mandate_AlreadyApproved();
    error Mandate_NotApproved();
    error Mandate_MandateIdAlreadyExists();

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
    }

    /**
     * @dev Creates a new payment mandate for a user
     * @param _user The user address who will be the payer
     * @param _mandateId The unique ID for the mandate (generated off-chain)
     * @param params Struct containing all mandate parameters
     * @notice Only executors can create mandates (business/platform creates on behalf of user)
     * @notice User must approve the mandate after creation via approveMandate()
     */
    function createMandate(address _user, bytes32 _mandateId, CreateMandateParams calldata params)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        returns (bytes32)
    {
        if (_user == address(0) || params.payee == address(0) || params.payee == _user) {
            revert Mandate_InvalidParameters();
        }
        if (_mandateId == bytes32(0)) revert Mandate_InvalidParameters();
        if (params.authority == _user) revert Mandate_InvalidParameters(); // Authority cannot be the payer
        if (!supportedTokens[params.token]) revert Mandate_UnsupportedToken();
        if (params.amountPerDebit == 0) revert Mandate_InvalidParameters();
        if (!params.isUnlimitedSpend && params.totalLimit == 0) {
            revert Mandate_InvalidParameters();
        }
        if (!params.isUnlimitedSpend && params.amountPerDebit > params.totalLimit) {
            revert Mandate_InvalidParameters();
        }
        if (params.frequency == 0) revert Mandate_InvalidParameters();
        if (params.startTime < block.timestamp) revert Mandate_InvalidParameters();
        if (params.endTime <= params.startTime) revert Mandate_InvalidParameters();

        if (mandates[_mandateId].payer != address(0)) revert Mandate_MandateIdAlreadyExists();

        _createMandateData(_user, _mandateId, params);

        uint256 effectiveTotalLimit = params.isUnlimitedSpend ? UNLIMITED_ALLOWANCE : params.totalLimit;

        emit MandateCreated(
            _mandateId,
            _user,
            params.payee,
            params.token,
            effectiveTotalLimit,
            params.amountPerDebit,
            params.frequency,
            params.startTime,
            params.endTime,
            params.debitType,
            params.frequencyType
        );

        return _mandateId;
    }

    function _createMandateData(address _payer, bytes32 _mandateId, CreateMandateParams calldata params) internal {
        uint256 effectiveTotalLimit = params.isUnlimitedSpend ? UNLIMITED_ALLOWANCE : params.totalLimit;

        mandates[_mandateId] = MandateData({
            payer: _payer,
            payee: params.payee,
            token: params.token,
            totalLimit: effectiveTotalLimit,
            amountPerDebit: params.amountPerDebit,
            frequency: params.frequency,
            startTime: params.startTime,
            endTime: params.endTime,
            totalPaid: 0,
            lastPaymentTime: 0,
            isActive: false,
            isApproved: false,
            createdAt: block.timestamp,
            debitType: params.debitType,
            frequencyType: params.frequencyType,
            isUnlimitedSpend: params.isUnlimitedSpend,
            authority: params.authority
        });
    }

    /**
     * @dev Approves and activates a mandate
     * @param _mandateId The mandate ID to approve
     * @notice Can be called by anyone (user, backend, or relayer) to activate the mandate
     *         Requires that the payer has already approved sufficient token allowance
     */
    function approveMandate(bytes32 _mandateId) external whenNotPaused {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.isApproved) revert Mandate_AlreadyApproved();
        if (mandate.isActive) revert Mandate_MandateNotActive();

        // Verify payer has approved sufficient tokens before activating mandate
        IERC20 token = IERC20(mandate.token);
        uint256 currentAllowance = token.allowance(mandate.payer, address(this));
        if (currentAllowance < mandate.totalLimit) {
            revert Mandate_InsufficientAllowance();
        }

        mandate.isApproved = true;
        mandate.isActive = true;

        emit MandateApproved(_mandateId, mandate.payer, block.timestamp);
    }

    /**
     * @dev Executes a mandate debit according to mandate rules
     * @param _mandateId The mandate ID to execute
     * @param _amount Amount to debit (must be <= amountPerDebit for Variable, exact amountPerDebit for Fixed)
     */
    function executeMandate(bytes32 _mandateId, uint256 _amount) external onlyRole(EXECUTOR_ROLE) whenNotPaused {
        _validateExecution(_mandateId, _amount);
        _processExecution(_mandateId, _amount);
    }

    function _validateExecution(bytes32 _mandateId, uint256 _amount) internal view {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isApproved) revert Mandate_NotApproved();
        if (!mandate.isActive) revert Mandate_MandateNotActive();
        if (block.timestamp > mandate.endTime) revert Mandate_MandateExpired();
        if (block.timestamp < mandate.startTime) {
            revert Mandate_ExecutionTooEarly();
        }

        // Check frequency constraint
        if (mandate.lastPaymentTime > 0) {
            if (block.timestamp < mandate.lastPaymentTime + mandate.frequency) {
                revert Mandate_ExecutionTooEarly();
            }
        }

        // Check debit type constraints
        if (mandate.debitType == DebitType.Fixed) {
            if (_amount != mandate.amountPerDebit) {
                revert Mandate_InvalidAmountForFixedDebit();
            }
        } else {
            // Variable
            if (_amount == 0 || _amount > mandate.amountPerDebit) {
                revert Mandate_InvalidAmountForVariableDebit();
            }
        }

        // Check total limit (unless unlimited)
        if (!mandate.isUnlimitedSpend && mandate.totalPaid + _amount > mandate.totalLimit) {
            revert Mandate_ExecutionExceedsLimit();
        }

        IERC20 token = IERC20(mandate.token);

        // Check allowance and balance
        uint256 allowance = token.allowance(mandate.payer, address(this));
        if (allowance < _amount) revert Mandate_InsufficientAllowance();

        uint256 balance = token.balanceOf(mandate.payer);
        if (balance < _amount) revert Mandate_InsufficientBalance();
    }

    function _processExecution(bytes32 _mandateId, uint256 _amount) internal {
        MandateData storage mandate = mandates[_mandateId];
        IERC20 token = IERC20(mandate.token);

        // Update mandate state
        mandate.totalPaid += _amount;
        mandate.lastPaymentTime = block.timestamp;

        // Execute transfer
        token.safeTransferFrom(mandate.payer, mandate.payee, _amount);

        emit MandateExecuted(_mandateId, mandate.payer, mandate.payee, mandate.token, _amount, block.timestamp);
    }

    /**
     * @dev Cancels a mandate (by payer or authority)
     * @param _mandateId The mandate ID to cancel
     */
    function cancelMandate(bytes32 _mandateId) external {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        // Allow cancellation by payer or authority (if set)
        if (mandate.payer != msg.sender && (mandate.authority == address(0) || mandate.authority != msg.sender)) {
            revert Mandate_UnauthorizedCaller();
        }
        if (!mandate.isActive) revert Mandate_MandateNotActive();

        mandate.isActive = false;

        emit MandateCanceled(_mandateId, msg.sender, block.timestamp);
    }

    /**
     * @dev Toggles mandate active state (pause/unpause)
     * @param _mandateId The mandate ID to toggle
     * @notice Only executor (authority/business) can toggle mandate state
     */
    function toggleMandateState(bytes32 _mandateId) external onlyRole(EXECUTOR_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();

        // Toggle the state
        mandate.isActive = !mandate.isActive;

        emit MandateStateToggled(_mandateId, msg.sender, mandate.isActive, block.timestamp);
    }

    /**
     * @dev Checks if a mandate can be executed
     * @param _mandateId The mandate ID to check
     * @param _amount Amount to check
     * @return canExecute Whether mandate can be executed
     * @return reason Reason if mandate cannot be executed
     */
    function canExecuteMandate(bytes32 _mandateId, uint256 _amount)
        external
        view
        returns (bool canExecute, string memory reason)
    {
        MandateData storage mandate = mandates[_mandateId];

        // Check mandate state
        if (mandate.payer == address(0)) {
            return (false, "Invalid mandate ID");
        }
        if (!mandate.isActive) {
            return (false, "Mandate not active");
        }

        // Check timing
        if (block.timestamp > mandate.endTime) {
            return (false, "Mandate expired");
        }
        if (block.timestamp < mandate.startTime) {
            return (false, "Execution too early - start time not reached");
        }
        if (mandate.lastPaymentTime > 0 && block.timestamp < mandate.lastPaymentTime + mandate.frequency) {
            return (false, "Execution too early - frequency constraint");
        }

        // Check amount
        if (mandate.debitType == DebitType.Fixed) {
            if (_amount != mandate.amountPerDebit) {
                return (false, "Fixed debit requires exact amount");
            }
        } else {
            if (_amount == 0 || _amount > mandate.amountPerDebit) {
                return (false, "Variable debit amount invalid");
            }
        }

        if (!mandate.isUnlimitedSpend && mandate.totalPaid + _amount > mandate.totalLimit) {
            return (false, "Amount exceeds total limit");
        }

        // Check balance and allowance
        IERC20 token = IERC20(mandate.token);
        if (token.allowance(mandate.payer, address(this)) < _amount) {
            return (false, "Insufficient allowance");
        }
        if (token.balanceOf(mandate.payer) < _amount) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    /**
     * @dev Gets mandate details
     * @param _mandateId The mandate ID
     * @return mandate The mandate struct
     */
    function getMandate(bytes32 _mandateId) external view returns (MandateData memory) {
        if (mandates[_mandateId].payer == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        return mandates[_mandateId];
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
    function emergencyCancelMandate(bytes32 _mandateId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.payer == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isActive) revert Mandate_MandateNotActive();

        mandate.isActive = false;

        emit MandateCanceled(_mandateId, mandate.payer, block.timestamp);
    }
}
