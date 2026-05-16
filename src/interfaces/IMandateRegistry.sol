// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IMandateRegistry
 * @dev Interface for the Mandate contract
 * @notice Updated to match current Mandate.sol implementation
 *
 * Mandate = granted authority (sender -> recipient -> token)
 * Policy = execution constraints (how authority may be used)
 * ExecutionState = mutable runtime bookkeeping (what happened so far)
 */
interface IMandateRegistry {
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

    event PolicyChanged(bytes32 indexed mandateId, bytes32 oldPolicyHash, bytes32 newPolicyHash, address indexed caller);

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
    ) external returns (bytes32);

    function executeMandate(bytes32 _mandateId, uint256 _amount, uint64 _nonce) external;

    function approveMandate(bytes32 _mandateId) external;

    function cancelMandate(bytes32 _mandateId) external;

    function modifyMandate(
        bytes32 _mandateId,
        bytes32 _newPolicyHash,
        uint256 _signatureNonce,
        bytes calldata _senderSignature
    ) external;

    function getMandate(bytes32 _mandateId) external view returns (MandateData memory);

    function getPolicy(bytes32 _mandateId) external view returns (Policy memory);

    function getExecutionState(bytes32 _mandateId) external view returns (ExecutionState memory);

    function canExecuteMandate(bytes32 _mandateId, uint256 _amount, uint64 _nonce)
        external
        view
        returns (bool canExecute, string memory reason);

    function pauseMandate(bytes32 _mandateId) external;

    function resumeMandate(bytes32 _mandateId) external;

    function addExecutor(address _executor) external;

    function removeExecutor(address _executor) external;

    function setSupportedToken(address _token, bool _supported) external;

    function pauseContract() external;

    function unpauseContract() external;

    function pauseExecution() external;

    function resumeExecution() external;
}
