// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title Mandate
 * @dev Recurring stablecoin payment execution with programmable policies
 * @notice Businesses create mandates with policies; users approve; Debyth executor executes within policy constraints
 */
contract Mandate is AccessControl, Pausable, Initializable {
    using SafeERC20 for IERC20;

    // Roles - separate admin from executor for security
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Constants
    uint256 public constant UNLIMITED_ALLOWANCE = type(uint256).max;

    // Policy types
    enum ChargeType {
        FIXED,     // Must execute exact amount per policy
        VARIABLE   // Can execute any amount up to limit per policy
    }

    enum Frequency {
        DAILY,
        WEEKLY,
        MONTHLY,
        ANNUALLY
    }

    // Mandate status
    enum MandateStatus {
        PENDING,      // Created but not yet approved
        ACTIVE,       // Approved and active
        PAUSED,       // Temporarily paused by executor
        EXPIRED,      // past end_time
        CANCELLED,    // Cancelled by sender or admin
        COMPLETE      // All limits reached
    }

    // Structs
    struct Policy {
        ChargeType chargeType;
        Frequency frequency;
        uint256 minIntervalSeconds;
        uint256 perExecutionLimit;
        uint256 lifetimeLimit;
        uint256 periodLimit;
        uint256 periodWindow; // seconds
        uint256 startAt;
        uint256 endAt;
        address[] allowedRecipients; // empty = any
        address[] allowedAssets;     // empty = any
        bytes32 policyHash;          // canonical policy hash for verification
    }

    struct MandateData {
        address sender;              // wallet authorizing funds (was: payer)
        address recipient;           // wallet receiving funds (was: payee)
        address token;               // stablecoin address
        uint256 totalLimit;
        uint256 perExecutionLimit;
        Policy policy;
        uint256 totalExecuted;       // total amount executed (was: totalPaid)
        uint256 lastExecutionTime;
        uint256 periodExecuted;      // amount executed in current period
        uint64 lastExecutionNonce;   // last executed nonce
        MandateStatus status;
        uint256 createdAt;
        bool isApproved;
        bytes32 policyHash;          // policy hash at creation time
    }

    // Mapping from mandate ID to mandate data
    mapping(bytes32 => MandateData) public mandates;

    // Nonce tracking for replay protection
    mapping(bytes32 => uint64) public usedNonces;

    // Token allowlist
    mapping(address => bool) public supportedTokens;

    // Execution pause flag
    bool public executionPaused;

    // Events - updated with new terminology and policy info
    event MandateCreated(
        bytes32 indexed mandateId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 totalLimit,
        uint256 perExecutionLimit,
        bytes32 policyHash,
        uint256 startAt,
        uint256 endAt
    );

    event MandateExecuted(
        bytes32 indexed mandateId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 totalCharged,
        uint256 timestamp,
        uint64 nonce,
        bytes32 policyHash
    );

    event MandateCancelled(bytes32 indexed mandateId, address indexed sender, uint256 timestamp);

    event MandateApproved(bytes32 indexed mandateId, address indexed user, uint256 timestamp);

    event MandatePaused(bytes32 indexed mandateId, address indexed caller, uint256 timestamp);

    event MandateResumed(bytes32 indexed mandateId, address indexed caller, uint256 timestamp);

    event MandateStateToggled(bytes32 indexed mandateId, address indexed caller, bool newState, uint256 timestamp);

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event TokenSupported(address indexed token, bool supported);

    event PolicyChanged(bytes32 indexed mandateId, bytes32 oldPolicyHash, bytes32 newPolicyHash, address indexed caller);

    // Pause events
    event ExecutionPaused(address indexed caller, uint256 timestamp);
    event ExecutionResumed(address indexed caller, uint256 timestamp);

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
    error Mandate_InvalidNonce(); // Replay protection
    error Mandate_RecipientNotAllowed();
    error Mandate_TokenNotAllowed();
    error Mandate_PolicyHashMismatch();
    error Mandate_ExecutionPaused();

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param _admin Admin address for DEFAULT_ADMIN_ROLE
     * @param _supportedTokens Initial list of supported token addresses
     * @param _executor Initial executor address
     */
    function initialize(address _admin, address[] memory _supportedTokens, address _executor)
        external
        initializer
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin); // Admin also has pause rights

        // Add supported tokens
        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            supportedTokens[_supportedTokens[i]] = true;
            emit TokenSupported(_supportedTokens[i], true);
        }

        // Grant executor role if specified
        if (_executor != address(0)) {
            _grantRole(EXECUTOR_ROLE, _executor);
        }
    }

    // ========== EXTERNAL FUNCTIONS ==========

    /**
     * @dev Creates a new mandate on-chain
     * @param _sender The sender wallet address
     * @param _mandateId Unique mandate identifier (generated off-chain)
     * @param _recipient Recipient wallet address
     * @param _token Token address (stablecoin)
     * @param _totalLimit Total lifetime limit (0 = unlimited)
     * @param _perExecutionLimit Maximum per execution
     * @param _chargeType FIXED or VARIABLE
     * @param _frequency Frequency enum
     * @param _minIntervalSeconds Minimum seconds between executions
     * @param _startAt Unix timestamp for start
     * @param _endAt Unix timestamp for end
     * @param _allowedRecipients List of allowed recipient addresses (empty = any)
     * @param _allowedAssets List of allowed token addresses (empty = any)
     * @param _policyHash Canonical policy hash for verification
     */
    function createMandate(
        address _sender,
        bytes32 _mandateId,
        address _recipient,
        address _token,
        uint256 _totalLimit,
        uint256 _perExecutionLimit,
        ChargeType _chargeType,
        Frequency _frequency,
        uint256 _minIntervalSeconds,
        uint256 _startAt,
        uint256 _endAt,
        address[] memory _allowedRecipients,
        address[] memory _allowedAssets,
        bytes32 _policyHash
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused returns (bytes32) {
        // Validation
        if (_sender == address(0) || _recipient == address(0) || _token == address(0)) {
            revert Mandate_InvalidParameters();
        }
        if (_mandateId == bytes32(0)) revert Mandate_InvalidParameters();
        if (_perExecutionLimit == 0) revert Mandate_InvalidParameters();
        if (!supportedTokens[_token]) revert Mandate_UnsupportedToken();
        if (_startAt > block.timestamp + 15) revert Mandate_InvalidParameters(); // Max 15s in future
        if (_endAt <= _startAt) revert Mandate_InvalidParameters();
        if (_totalLimit != 0 && _perExecutionLimit > _totalLimit) {
            revert Mandate_InvalidParameters();
        }
        if (_minIntervalSeconds == 0) revert Mandate_InvalidParameters();

        if (mandates[_mandateId].sender != address(0)) revert Mandate_MandateIdAlreadyExists();

        // Create policy
        Policy memory policy = Policy({
            chargeType: _chargeType,
            frequency: _frequency,
            minIntervalSeconds: _minIntervalSeconds,
            perExecutionLimit: _perExecutionLimit,
            lifetimeLimit: _totalLimit,
            periodLimit: 0, // Optional period limit
            periodWindow: 0, // Optional period window
            startAt: _startAt,
            endAt: _endAt,
            allowedRecipients: _allowedRecipients,
            allowedAssets: _allowedAssets,
            policyHash: _policyHash
        });

        _createMandateData(_sender, _mandateId, _recipient, _token, _totalLimit, _perExecutionLimit, policy, _policyHash);

        emit MandateCreated(
            _mandateId,
            _sender,
            _recipient,
            _token,
            _totalLimit,
            _perExecutionLimit,
            _policyHash,
            _startAt,
            _endAt
        );

        return _mandateId;
    }

    function _createMandateData(
        address _sender,
        bytes32 _mandateId,
        address _recipient,
        address _token,
        uint256 _totalLimit,
        uint256 _perExecutionLimit,
        Policy memory _policy,
        bytes32 _policyHash
    ) internal {
        uint256 effectiveTotalLimit = _totalLimit == 0 ? UNLIMITED_ALLOWANCE : _totalLimit;

        mandates[_mandateId] = MandateData({
            sender: _sender,
            recipient: _recipient,
            token: _token,
            totalLimit: effectiveTotalLimit,
            perExecutionLimit: _perExecutionLimit,
            policy: _policy,
            totalExecuted: 0,
            lastExecutionTime: 0,
            periodExecuted: 0,
            lastExecutionNonce: 0,
            status: MandateStatus.PENDING,
            createdAt: block.timestamp,
            isApproved: false,
            policyHash: _policyHash
        });
    }

    /**
     * @dev Approves and activates a mandate
     * @param _mandateId The mandate ID to approve
     * @notice Can be called by anyone (user, backend, or relayer) to activate the mandate
     *         Requires that the sender has already approved sufficient token allowance
     */
    function approveMandate(bytes32 _mandateId) external whenNotPaused {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.isApproved) revert Mandate_AlreadyApproved();
        if (mandate.status != MandateStatus.PENDING) revert Mandate_InvalidParameters();

        // Verify sender has approved sufficient tokens before activating mandate
        IERC20 token = IERC20(mandate.token);
        uint256 currentAllowance = token.allowance(mandate.sender, address(this));
        if (mandate.totalLimit != UNLIMITED_ALLOWANCE && currentAllowance < mandate.totalLimit) {
            revert Mandate_InsufficientAllowance();
        }

        mandate.isApproved = true;
        mandate.status = MandateStatus.ACTIVE;

        emit MandateApproved(_mandateId, mandate.sender, block.timestamp);
    }

    /**
     * @dev Executes a mandate debit
     * @param _mandateId The mandate ID to execute
     * @param _amount Amount to debit
     * @param _nonce Unique nonce for this execution (replay protection)
     */
    function executeMandate(bytes32 _mandateId, uint256 _amount, uint64 _nonce)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
    {
        // Check global execution pause
        if (executionPaused) revert Mandate_ExecutionPaused();

        _validateExecution(_mandateId, _amount, _nonce);
        _processExecution(_mandateId, _amount, _nonce);
    }

    function _validateExecution(bytes32 _mandateId, uint256 _amount, uint64 _nonce) internal {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isApproved) revert Mandate_NotApproved();
        if (mandate.status != MandateStatus.ACTIVE) revert Mandate_MandateNotActive();

        // Check nonce - replay protection
        if (_nonce == 0) revert Mandate_InvalidNonce();
        if (_nonce <= mandate.lastExecutionNonce) revert Mandate_InvalidNonce();
        if (usedNonces[_mandateId] >= _nonce) revert Mandate_InvalidNonce();

        // Time-based checks
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp > mandate.policy.endAt) revert Mandate_MandateExpired();
        if (currentTimestamp < mandate.policy.startAt) {
            revert Mandate_ExecutionTooEarly();
        }

        // Check frequency constraint
        if (mandate.lastExecutionTime > 0) {
            if (currentTimestamp < mandate.lastExecutionTime + mandate.policy.minIntervalSeconds) {
                revert Mandate_ExecutionTooEarly();
            }
        }

        // Check debit type constraints
        if (mandate.policy.chargeType == ChargeType.FIXED) {
            if (_amount != mandate.perExecutionLimit) {
                revert Mandate_InvalidAmountForFixedDebit();
            }
        } else {
            // Variable: must be > 0 and <= limit
            if (_amount == 0 || _amount > mandate.perExecutionLimit) {
                revert Mandate_InvalidAmountForVariableDebit();
            }
        }

        // Check total limit (unless unlimited)
        if (mandate.totalLimit != UNLIMITED_ALLOWANCE &&
            mandate.totalExecuted + _amount > mandate.totalLimit) {
            revert Mandate_ExecutionExceedsLimit();
        }

        // Check period limit if configured
        if (mandate.policy.periodLimit > 0 && mandate.policy.periodWindow > 0) {
            if (mandate.periodExecuted + _amount > mandate.policy.periodLimit) {
                revert Mandate_ExecutionExceedsLimit();
            }
        }

        // Check allowed recipients (if list is non-empty)
        if (mandate.policy.allowedRecipients.length > 0) {
            bool allowed = false;
            for (uint256 i = 0; i < mandate.policy.allowedRecipients.length; i++) {
                if (mandate.policy.allowedRecipients[i] == mandate.recipient) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) revert Mandate_RecipientNotAllowed();
        }

        // Check allowed assets (if list is non-empty)
        if (mandate.policy.allowedAssets.length > 0) {
            bool allowed = false;
            for (uint256 i = 0; i < mandate.policy.allowedAssets.length; i++) {
                if (mandate.policy.allowedAssets[i] == mandate.token) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) revert Mandate_TokenNotAllowed();
        }

        // Check policy hash matches (integrity check)
        if (mandate.policyHash != mandate.policy.policyHash) {
            revert Mandate_PolicyHashMismatch();
        }

        // Check allowance and balance
        IERC20 token = IERC20(mandate.token);
        uint256 allowance = token.allowance(mandate.sender, address(this));
        if (allowance < _amount) revert Mandate_InsufficientAllowance();

        uint256 balance = token.balanceOf(mandate.sender);
        if (balance < _amount) revert Mandate_InsufficientBalance();
    }

    function _processExecution(bytes32 _mandateId, uint256 _amount, uint64 _nonce) internal {
        MandateData storage mandate = mandates[_mandateId];
        IERC20 token = IERC20(mandate.token);

        // Update mandate state
        mandate.totalExecuted += _amount;
        mandate.lastExecutionTime = block.timestamp;
        mandate.lastExecutionNonce = _nonce;

        // Update period execution
        if (mandate.policy.periodLimit > 0 && mandate.policy.periodWindow > 0) {
            uint256 currentPeriodStart = block.timestamp - (block.timestamp % mandate.policy.periodWindow);
            if (mandate.lastExecutionTime < currentPeriodStart) {
                mandate.periodExecuted = 0;
            }
            mandate.periodExecuted += _amount;
        }

        // Update nonce tracking
        usedNonces[_mandateId] = _nonce;

        // Execute transfer directly to recipient (not authority)
        token.safeTransferFrom(mandate.sender, mandate.recipient, _amount);

        // Check if mandate is complete
        if (mandate.totalLimit != UNLIMITED_ALLOWANCE &&
            mandate.totalExecuted >= mandate.totalLimit) {
            mandate.status = MandateStatus.COMPLETE;
        }

        emit MandateExecuted(
            _mandateId,
            mandate.sender,
            mandate.recipient,
            mandate.token,
            _amount,
            mandate.totalExecuted,
            block.timestamp,
            _nonce,
            mandate.policyHash
        );
    }

    /**
     * @dev Cancels a mandate
     * @param _mandateId The mandate ID to cancel
     * @notice Can be called by sender, authority, or admin (for emergency)
     */
    function cancelMandate(bytes32 _mandateId) external {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status == MandateStatus.CANCELLED) return;
        if (mandate.status == MandateStatus.COMPLETE) return;

        // Allow cancellation by: sender, executor, or admin
        if (msg.sender != mandate.sender &&
            !hasRole(EXECUTOR_ROLE, msg.sender) &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Mandate_UnauthorizedCaller();
        }

        mandate.status = MandateStatus.CANCELLED;

        emit MandateCancelled(_mandateId, msg.sender, block.timestamp);
    }

    /**
     * @dev Pauses a mandate (executor only)
     * @param _mandateId The mandate ID to pause
     */
    function pauseMandate(bytes32 _mandateId) external onlyRole(EXECUTOR_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status == MandateStatus.PAUSED) return;
        if (mandate.status != MandateStatus.ACTIVE) revert Mandate_MandateNotActive();

        mandate.status = MandateStatus.PAUSED;

        emit MandatePaused(_mandateId, msg.sender, block.timestamp);
    }

    /**
     * @dev Resumes a paused mandate (executor only)
     * @param _mandateId The mandate ID to resume
     */
    function resumeMandate(bytes32 _mandateId) external onlyRole(EXECUTOR_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status != MandateStatus.PAUSED) revert Mandate_MandateNotActive();

        mandate.status = MandateStatus.ACTIVE;

        emit MandateResumed(_mandateId, msg.sender, block.timestamp);
    }

    /**
     * @dev Modifies a mandate's policy (requires sender consent via signature)
     * @param _mandateId The mandate ID to modify
     * @param _newPolicyHash New policy hash
     * @param _senderSignature Signature from sender approving the change
     * @notice Only the original sender can approve policy changes
     */
    function modifyMandate(bytes32 _mandateId, bytes32 _newPolicyHash, bytes memory _senderSignature)
        external
    {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status != MandateStatus.ACTIVE) revert Mandate_MandateNotActive();
        if (msg.sender != mandate.sender) revert Mandate_UnauthorizedCaller();

        // Verify sender signature on policy hash
        bytes32 messageHash = keccak256(abi.encodePacked(_newPolicyHash));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ECDSA.recover(ethSignedMessageHash, _senderSignature);
        if (signer != mandate.sender) revert Mandate_UnauthorizedCaller();

        // Update policy
        bytes32 oldPolicyHash = mandate.policyHash;
        mandate.policy.policyHash = _newPolicyHash;
        mandate.policyHash = _newPolicyHash;

        emit PolicyChanged(_mandateId, oldPolicyHash, _newPolicyHash, msg.sender);
    }

    /**
     * @dev Toggles mandate active state (pause/unpause) - kept for backwards compat
     * @param _mandateId The mandate ID to toggle
     * @notice DEPRECATED: Use pauseMandate/resumeMandate instead
     */
    function toggleMandateState(bytes32 _mandateId) external {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();

        if (mandate.status == MandateStatus.ACTIVE) {
            mandate.status = MandateStatus.PAUSED;
            emit MandatePaused(_mandateId, msg.sender, block.timestamp);
        } else if (mandate.status == MandateStatus.PAUSED) {
            mandate.status = MandateStatus.ACTIVE;
            emit MandateResumed(_mandateId, msg.sender, block.timestamp);
        }
    }

    /**
     * @dev Check if a mandate can be executed (view function)
     * @param _mandateId The mandate ID to check
     * @param _amount Amount to check
     * @param _nonce Nonce to check
     * @return canExecute Whether mandate can be executed
     * @return reason Reason if mandate cannot be executed
     */
    function canExecuteMandate(bytes32 _mandateId, uint256 _amount, uint64 _nonce)
        external
        view
        returns (bool canExecute, string memory reason)
    {
        MandateData storage mandate = mandates[_mandateId];

        // Check mandate exists
        if (mandate.sender == address(0)) {
            return (false, "Invalid mandate ID");
        }

        // Check approval
        if (!mandate.isApproved) {
            return (false, "Mandate not approved");
        }

        // Check active status
        if (mandate.status != MandateStatus.ACTIVE) {
            return (false, "Mandate not active");
        }

        // Check execution pause
        if (executionPaused) {
            return (false, "Execution paused globally");
        }

        // Check time constraints
        if (block.timestamp > mandate.policy.endAt) {
            return (false, "Mandate expired");
        }
        if (block.timestamp < mandate.policy.startAt) {
            return (false, "Execution too early - start time not reached");
        }
        if (mandate.lastExecutionTime > 0 &&
            block.timestamp < mandate.lastExecutionTime + mandate.policy.minIntervalSeconds) {
            return (false, "Execution too early - frequency constraint");
        }

        // Check nonce
        if (_nonce == 0) {
            return (false, "Invalid nonce");
        }
        if (_nonce <= mandate.lastExecutionNonce) {
            return (false, "Nonce already used");
        }

        // Check amount constraints
        if (mandate.policy.chargeType == ChargeType.FIXED) {
            if (_amount != mandate.perExecutionLimit) {
                return (false, "Fixed debit requires exact amount");
            }
        } else {
            if (_amount == 0 || _amount > mandate.perExecutionLimit) {
                return (false, "Variable debit amount invalid");
            }
        }

        // Check limits
        if (mandate.totalLimit != UNLIMITED_ALLOWANCE &&
            mandate.totalExecuted + _amount > mandate.totalLimit) {
            return (false, "Amount exceeds total limit");
        }

        // Check balance and allowance
        IERC20 token = IERC20(mandate.token);
        if (token.allowance(mandate.sender, address(this)) < _amount) {
            return (false, "Insufficient allowance");
        }
        if (token.balanceOf(mandate.sender) < _amount) {
            return (false, "Insufficient balance");
        }

        return (true, "");
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @dev Gets mandate details
     * @param _mandateId The mandate ID
     * @return mandate The mandate data struct
     */
    function getMandate(bytes32 _mandateId)
        external
        view
        returns (MandateData memory mandate)
    {
        if (mandates[_mandateId].sender == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        return mandates[_mandateId];
    }

    /**
     * @dev Gets mandate policy
     * @param _mandateId The mandate ID
     * @return policy The policy struct
     */
    function getPolicy(bytes32 _mandateId)
        external
        view
        returns (Policy memory policy)
    {
        if (mandates[_mandateId].sender == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        return mandates[_mandateId].policy;
    }

    // ========== ADMIN FUNCTIONS ==========

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
     * @dev Pauses the entire contract (all mandates)
     */
    function pauseContract() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses the entire contract
     */
    function unpauseContract() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Pauses all mandate executions (separate from contract pause)
     * @notice Emergency control for executive team
     */
    function pauseExecution() external onlyRole(PAUSER_ROLE) {
        executionPaused = true;
        emit ExecutionPaused(msg.sender, block.timestamp);
    }

    /**
     * @dev Resumes mandate executions
     */
    function resumeExecution() external onlyRole(PAUSER_ROLE) {
        executionPaused = false;
        emit ExecutionResumed(msg.sender, block.timestamp);
    }

    /**
     * @dev Emergency cancel mandate (admin only)
     * @param _mandateId The mandate ID to cancel
     */
    function emergencyCancelMandate(bytes32 _mandateId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status != MandateStatus.ACTIVE && mandate.status != MandateStatus.PAUSED) {
            return;
        }

        mandate.status = MandateStatus.CANCELLED;

        emit MandateCancelled(_mandateId, msg.sender, block.timestamp);
    }

    /**
     * @dev Gets the current execution pause state
     * @return paused Whether execution is paused
     */
    function isExecutionPaused() external view returns (bool) {
        return executionPaused;
    }
}
