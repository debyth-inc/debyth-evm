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
 * @notice
 *   Mandate = granted authority (sender -> recipient -> token)
 *   Policy = execution constraints (how authority may be used)
 *   ExecutionState = mutable runtime bookkeeping (what happened so far)
 */
contract Mandate is AccessControl, Pausable, Initializable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Constants
    uint256 public constant UNLIMITED_ALLOWANCE = type(uint256).max;

    // Enums
    enum ChargeType {
        FIXED,
        VARIABLE
    }

    enum Frequency {
        DAILY,
        WEEKLY,
        MONTHLY,
        ANNUALLY
    }

    enum MandateStatus {
        PENDING,
        ACTIVE,
        PAUSED,
        EXPIRED,
        CANCELLED,
        COMPLETE
    }

    // Policy = execution constraints only
    struct Policy {
        Frequency frequency;
        uint256 minIntervalSeconds;
        uint256 perExecutionLimit;
        uint256 periodLimit;
        uint256 periodWindow;
        bytes32 policyHash;
    }

    // ExecutionState = runtime bookkeeping only
    struct ExecutionState {
        uint256 totalExecuted;
        uint256 periodExecuted;
        uint256 lastExecutionTime;
        uint256 lastPeriodTimestamp;
        uint64 executionNonce;
    }

    // Mandate = granted authority
    struct MandateData {
        address authority;
        address sender;
        address recipient;
        address token;
        uint256 authorizedLimit;
        ChargeType chargeType;
        uint256 startAt;
        uint256 endAt;
        Policy policy;
        ExecutionState executionState;
        MandateStatus status;
        uint256 createdAt;
        bool isApproved;
        uint64 modifySignatureNonce;
    }

    // Mapping from mandate ID to mandate data
    mapping(bytes32 => MandateData) public mandates;

    // Signature nonce tracking for modifyMandate replay protection
    mapping(address => mapping(uint256 => bool)) public usedSignatureNonces;

    // Token allowlist
    mapping(address => bool) public supportedTokens;

    // Execution pause flag
    bool public executionPaused;

    // Events
    event MandateCreated(
        bytes32 indexed mandateId,
        address indexed authority,
        address indexed sender,
        address recipient,
        address token,
        uint256 authorizedLimit,
        ChargeType chargeType,
        uint256 startAt,
        uint256 endAt,
        bytes32 policyHash
    );

    event MandateExecuted(
        bytes32 indexed mandateId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 totalExecuted,
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
    error Mandate_InvalidNonce();
    error Mandate_PolicyExceedsAuthority();
    error Mandate_ExecutionPaused();
    error Mandate_InvalidSignature();
    error Mandate_SignatureNonceUsed();

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
        _grantRole(PAUSER_ROLE, _admin);

        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            supportedTokens[_supportedTokens[i]] = true;
            emit TokenSupported(_supportedTokens[i], true);
        }

        if (_executor != address(0)) {
            _grantRole(EXECUTOR_ROLE, _executor);
        }
    }

    // ========== EXTERNAL FUNCTIONS ==========

    /**
     * @dev Creates a new mandate on-chain
     * @param _sender The sender wallet address authorizing funds
     * @param _mandateId Unique mandate identifier (generated off-chain)
     * @param _recipient Recipient wallet address
     * @param _token Token address (stablecoin)
     * @param _authorizedLimit Maximum authority granted by sender (0 = unlimited)
     * @param _chargeType FIXED or VARIABLE
     * @param _startAt Unix timestamp for start
     * @param _endAt Unix timestamp for end
     * @param _frequency Frequency enum
     * @param _minIntervalSeconds Minimum seconds between executions
     * @param _perExecutionLimit Maximum per execution
     * @param _periodLimit Optional period limit (0 = disabled)
     * @param _periodWindow Optional period window in seconds (0 = disabled)
     * @param _policyHash Canonical policy hash for verification
     */
    function createMandate(
        address _sender,
        bytes32 _mandateId,
        address _recipient,
        address _token,
        uint256 _authorizedLimit,
        ChargeType _chargeType,
        uint256 _startAt,
        uint256 _endAt,
        Frequency _frequency,
        uint256 _minIntervalSeconds,
        uint256 _perExecutionLimit,
        uint256 _periodLimit,
        uint256 _periodWindow,
        bytes32 _policyHash
    ) external onlyRole(EXECUTOR_ROLE) whenNotPaused returns (bytes32) {
        if (_sender == address(0) || _recipient == address(0) || _token == address(0)) {
            revert Mandate_InvalidParameters();
        }
        if (_mandateId == bytes32(0)) revert Mandate_InvalidParameters();
        if (_perExecutionLimit == 0) revert Mandate_InvalidParameters();
        if (!supportedTokens[_token]) revert Mandate_UnsupportedToken();
        if (_startAt > block.timestamp + 15) revert Mandate_InvalidParameters();
        if (_endAt <= _startAt) revert Mandate_InvalidParameters();
        if (_minIntervalSeconds == 0) revert Mandate_InvalidParameters();

        // Policy constraints may tighten authority but never broaden it
        if (_authorizedLimit != 0 && _perExecutionLimit > _authorizedLimit) {
            revert Mandate_PolicyExceedsAuthority();
        }

        if (mandates[_mandateId].sender != address(0)) revert Mandate_MandateIdAlreadyExists();

        uint256 effectiveLimit = _authorizedLimit == 0 ? UNLIMITED_ALLOWANCE : _authorizedLimit;

        mandates[_mandateId] = MandateData({
            authority: msg.sender,
            sender: _sender,
            recipient: _recipient,
            token: _token,
            authorizedLimit: effectiveLimit,
            chargeType: _chargeType,
            startAt: _startAt,
            endAt: _endAt,
            policy: Policy({
                frequency: _frequency,
                minIntervalSeconds: _minIntervalSeconds,
                perExecutionLimit: _perExecutionLimit,
                periodLimit: _periodLimit,
                periodWindow: _periodWindow,
                policyHash: _policyHash
            }),
            executionState: ExecutionState({
                totalExecuted: 0,
                periodExecuted: 0,
                lastExecutionTime: 0,
                lastPeriodTimestamp: 0,
                executionNonce: 0
            }),
            status: MandateStatus.PENDING,
            createdAt: block.timestamp,
            isApproved: false,
            modifySignatureNonce: 0
        });

        emit MandateCreated(
            _mandateId,
            msg.sender,
            _sender,
            _recipient,
            _token,
            _authorizedLimit,
            _chargeType,
            _startAt,
            _endAt,
            _policyHash
        );

        return _mandateId;
    }

    /**
     * @dev Approves and activates a mandate
     * @param _mandateId The mandate ID to approve
     */
    function approveMandate(bytes32 _mandateId) external whenNotPaused {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.isApproved) revert Mandate_AlreadyApproved();
        if (mandate.status != MandateStatus.PENDING) revert Mandate_InvalidParameters();

        IERC20 token = IERC20(mandate.token);
        uint256 currentAllowance = token.allowance(mandate.sender, address(this));
        if (mandate.authorizedLimit != UNLIMITED_ALLOWANCE && currentAllowance < mandate.authorizedLimit) {
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
        if (executionPaused) revert Mandate_ExecutionPaused();

        _validateExecution(_mandateId, _amount, _nonce);
        _processExecution(_mandateId, _amount, _nonce);
    }

    function _validateExecution(bytes32 _mandateId, uint256 _amount, uint64 _nonce) internal view {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (!mandate.isApproved) revert Mandate_NotApproved();
        if (mandate.status != MandateStatus.ACTIVE) revert Mandate_MandateNotActive();

        if (_nonce == 0) revert Mandate_InvalidNonce();
        if (_nonce <= mandate.executionState.executionNonce) revert Mandate_InvalidNonce();

        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp > mandate.endAt) revert Mandate_MandateExpired();
        if (currentTimestamp < mandate.startAt) revert Mandate_ExecutionTooEarly();

        if (mandate.executionState.lastExecutionTime > 0) {
            if (currentTimestamp < mandate.executionState.lastExecutionTime + mandate.policy.minIntervalSeconds) {
                revert Mandate_ExecutionTooEarly();
            }
        }

        if (mandate.chargeType == ChargeType.FIXED) {
            if (_amount != mandate.policy.perExecutionLimit) {
                revert Mandate_InvalidAmountForFixedDebit();
            }
        } else {
            if (_amount == 0 || _amount > mandate.policy.perExecutionLimit) {
                revert Mandate_InvalidAmountForVariableDebit();
            }
        }

        if (mandate.authorizedLimit != UNLIMITED_ALLOWANCE &&
            mandate.executionState.totalExecuted + _amount > mandate.authorizedLimit) {
            revert Mandate_ExecutionExceedsLimit();
        }

        if (mandate.policy.periodLimit > 0 && mandate.policy.periodWindow > 0) {
            uint256 currentPeriodStart = currentTimestamp - (currentTimestamp % mandate.policy.periodWindow);
            uint256 currentPeriodExecuted = mandate.executionState.lastPeriodTimestamp < currentPeriodStart
                ? 0
                : mandate.executionState.periodExecuted;
            if (currentPeriodExecuted + _amount > mandate.policy.periodLimit) {
                revert Mandate_ExecutionExceedsLimit();
            }
        }

        IERC20 token = IERC20(mandate.token);
        uint256 allowance = token.allowance(mandate.sender, address(this));
        if (allowance < _amount) revert Mandate_InsufficientAllowance();

        uint256 balance = token.balanceOf(mandate.sender);
        if (balance < _amount) revert Mandate_InsufficientBalance();
    }

    function _processExecution(bytes32 _mandateId, uint256 _amount, uint64 _nonce) internal {
        MandateData storage mandate = mandates[_mandateId];
        IERC20 token = IERC20(mandate.token);

        uint256 currentTimestamp = block.timestamp;

        // Update period execution
        if (mandate.policy.periodLimit > 0 && mandate.policy.periodWindow > 0) {
            uint256 currentPeriodStart = currentTimestamp - (currentTimestamp % mandate.policy.periodWindow);
            if (mandate.executionState.lastPeriodTimestamp < currentPeriodStart) {
                mandate.executionState.periodExecuted = 0;
                mandate.executionState.lastPeriodTimestamp = currentPeriodStart;
            }
            mandate.executionState.periodExecuted += _amount;
        }

        // Update execution state
        mandate.executionState.totalExecuted += _amount;
        mandate.executionState.lastExecutionTime = currentTimestamp;
        mandate.executionState.executionNonce = _nonce;

        token.safeTransferFrom(mandate.sender, mandate.recipient, _amount);

        if (mandate.authorizedLimit != UNLIMITED_ALLOWANCE &&
            mandate.executionState.totalExecuted >= mandate.authorizedLimit) {
            mandate.status = MandateStatus.COMPLETE;
        }

        emit MandateExecuted(
            _mandateId,
            mandate.sender,
            mandate.recipient,
            mandate.token,
            _amount,
            mandate.executionState.totalExecuted,
            currentTimestamp,
            _nonce,
            mandate.policy.policyHash
        );
    }

    /**
     * @dev Cancels a mandate
     * @param _mandateId The mandate ID to cancel
     */
    function cancelMandate(bytes32 _mandateId) external {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status == MandateStatus.CANCELLED) return;
        if (mandate.status == MandateStatus.COMPLETE) return;

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
     * @param _signatureNonce Unique nonce for replay protection
     * @param _senderSignature Signature from sender approving the change
     */
    function modifyMandate(
        bytes32 _mandateId,
        bytes32 _newPolicyHash,
        uint256 _signatureNonce,
        bytes memory _senderSignature
    ) external {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status != MandateStatus.ACTIVE) revert Mandate_MandateNotActive();

        if (usedSignatureNonces[mandate.sender][_signatureNonce]) revert Mandate_SignatureNonceUsed();

        bytes32 messageHash = keccak256(abi.encode(_mandateId, _newPolicyHash, _signatureNonce, block.chainid));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ECDSA.recover(ethSignedMessageHash, _senderSignature);
        if (signer != mandate.sender) revert Mandate_InvalidSignature();

        usedSignatureNonces[mandate.sender][_signatureNonce] = true;

        bytes32 oldPolicyHash = mandate.policy.policyHash;
        mandate.policy.policyHash = _newPolicyHash;
        mandate.modifySignatureNonce++;

        emit PolicyChanged(_mandateId, oldPolicyHash, _newPolicyHash, msg.sender);
    }

    /**
     * @dev Toggles mandate active state (pause/unpause)
     * @param _mandateId The mandate ID to toggle
     * @notice DEPRECATED: Use pauseMandate/resumeMandate instead
     */
    function toggleMandateState(bytes32 _mandateId) external onlyRole(EXECUTOR_ROLE) {
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

        if (mandate.sender == address(0)) {
            return (false, "Invalid mandate ID");
        }
        if (!mandate.isApproved) {
            return (false, "Mandate not approved");
        }
        if (mandate.status != MandateStatus.ACTIVE) {
            return (false, "Mandate not active");
        }
        if (executionPaused) {
            return (false, "Execution paused globally");
        }
        if (block.timestamp > mandate.endAt) {
            return (false, "Mandate expired");
        }
        if (block.timestamp < mandate.startAt) {
            return (false, "Execution too early - start time not reached");
        }
        if (mandate.executionState.lastExecutionTime > 0 &&
            block.timestamp < mandate.executionState.lastExecutionTime + mandate.policy.minIntervalSeconds) {
            return (false, "Execution too early - frequency constraint");
        }
        if (_nonce == 0) {
            return (false, "Invalid nonce");
        }
        if (_nonce <= mandate.executionState.executionNonce) {
            return (false, "Nonce already used");
        }
        if (mandate.chargeType == ChargeType.FIXED) {
            if (_amount != mandate.policy.perExecutionLimit) {
                return (false, "Fixed debit requires exact amount");
            }
        } else {
            if (_amount == 0 || _amount > mandate.policy.perExecutionLimit) {
                return (false, "Variable debit amount invalid");
            }
        }
        if (mandate.authorizedLimit != UNLIMITED_ALLOWANCE &&
            mandate.executionState.totalExecuted + _amount > mandate.authorizedLimit) {
            return (false, "Amount exceeds authorized limit");
        }
        if (mandate.policy.periodLimit > 0 && mandate.policy.periodWindow > 0) {
            uint256 currentPeriodStart = block.timestamp - (block.timestamp % mandate.policy.periodWindow);
            uint256 currentPeriodExecuted = mandate.executionState.lastPeriodTimestamp < currentPeriodStart
                ? 0
                : mandate.executionState.periodExecuted;
            if (currentPeriodExecuted + _amount > mandate.policy.periodLimit) {
                return (false, "Amount exceeds period limit");
            }
        }
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

    function getExecutionState(bytes32 _mandateId)
        external
        view
        returns (ExecutionState memory state)
    {
        if (mandates[_mandateId].sender == address(0)) {
            revert Mandate_InvalidMandateId();
        }
        return mandates[_mandateId].executionState;
    }

    // ========== ADMIN FUNCTIONS ==========

    function addExecutor(address _executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(EXECUTOR_ROLE, _executor);
        emit ExecutorAdded(_executor);
    }

    function removeExecutor(address _executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(EXECUTOR_ROLE, _executor);
        emit ExecutorRemoved(_executor);
    }

    function setSupportedToken(address _token, bool _supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedTokens[_token] = _supported;
        emit TokenSupported(_token, _supported);
    }

    function pauseContract() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpauseContract() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function pauseExecution() external onlyRole(PAUSER_ROLE) {
        executionPaused = true;
        emit ExecutionPaused(msg.sender, block.timestamp);
    }

    function resumeExecution() external onlyRole(PAUSER_ROLE) {
        executionPaused = false;
        emit ExecutionResumed(msg.sender, block.timestamp);
    }

    function emergencyCancelMandate(bytes32 _mandateId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MandateData storage mandate = mandates[_mandateId];

        if (mandate.sender == address(0)) revert Mandate_InvalidMandateId();
        if (mandate.status == MandateStatus.CANCELLED || mandate.status == MandateStatus.COMPLETE) {
            return;
        }

        mandate.status = MandateStatus.CANCELLED;

        emit MandateCancelled(_mandateId, msg.sender, block.timestamp);
    }

    function isExecutionPaused() external view returns (bool) {
        return executionPaused;
    }
}
