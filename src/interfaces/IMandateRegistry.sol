// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IMandateRegistry
 * @dev Interface for mandate registry functionality
 */
interface IMandateRegistry {
    struct MandateData {
        address payer;
        address payee;
        address token;
        uint256 totalLimit;
        uint256 perPaymentLimit;
        uint256 frequency;
        uint256 startTime;
        uint256 endTime;
        uint256 totalPaid;
        uint256 lastPaymentTime;
        bool isActive;
        uint256 createdAt;
    }

    struct ApprovalSettings {
        uint256 lowAllowanceThreshold;
        uint256 criticalThreshold;
        bool autoPauseEnabled;
        bool isPausedBySystem;
    }

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

    function createMandate(
        address payee,
        address token,
        uint256 totalLimit,
        uint256 perPaymentLimit,
        uint256 frequency,
        uint256 startTime,
        uint256 endTime
    ) external returns (uint256);

    function executePayment(uint256 mandateId, uint256 amount) external;

    function cancelMandate(uint256 mandateId) external;

    function getMandate(uint256 mandateId) external view returns (MandateData memory);

    function getUserMandates(address user) external view returns (uint256[] memory);

    function canExecutePayment(uint256 mandateId, uint256 amount) external view returns (bool, string memory);
}
