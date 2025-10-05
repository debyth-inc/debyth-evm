// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MandateValidation
 * @dev Library for mandate validation logic
 */
library MandateValidation {
    error InvalidPayee();
    error InvalidToken();
    error InvalidAmounts();
    error InvalidTimeframe();
    error InvalidFrequency();

    struct ValidationParams {
        address payer;
        address payee;
        address token;
        uint256 totalLimit;
        uint256 perPaymentLimit;
        uint256 frequency;
        uint256 startTime;
        uint256 endTime;
        mapping(address => bool) supportedTokens;
    }

    /**
     * @dev Validates mandate creation parameters
     */
    function validateMandateCreation(
        address payer,
        address payee,
        address token,
        uint256 totalLimit,
        uint256 perPaymentLimit,
        uint256 frequency,
        uint256 startTime,
        uint256 endTime,
        mapping(address => bool) storage supportedTokens
    ) internal view {
        // Validate payee
        if (payee == address(0) || payee == payer) {
            revert InvalidPayee();
        }

        // Validate token
        if (!supportedTokens[token]) {
            revert InvalidToken();
        }

        // Validate amounts
        if (totalLimit == 0 || perPaymentLimit == 0 || perPaymentLimit > totalLimit) {
            revert InvalidAmounts();
        }

        // Validate frequency
        if (frequency == 0) {
            revert InvalidFrequency();
        }

        // Validate timeframe
        if (startTime < block.timestamp || endTime <= startTime) {
            revert InvalidTimeframe();
        }
    }

    /**
     * @dev Validates payment execution parameters
     */
    function validatePaymentExecution(
        uint256 amount,
        uint256 perPaymentLimit,
        uint256 totalPaid,
        uint256 totalLimit,
        uint256 lastPaymentTime,
        uint256 frequency,
        uint256 startTime,
        uint256 endTime
    ) internal view returns (bool valid, string memory reason) {
        // Check timing constraints
        if (block.timestamp < startTime) {
            return (false, "Payment too early - start time not reached");
        }

        if (block.timestamp > endTime) {
            return (false, "Mandate expired");
        }

        if (lastPaymentTime > 0 && block.timestamp < lastPaymentTime + frequency) {
            return (false, "Payment too early - frequency constraint");
        }

        // Check amount constraints
        if (amount == 0 || amount > perPaymentLimit) {
            return (false, "Amount exceeds per-payment limit");
        }

        if (totalPaid + amount > totalLimit) {
            return (false, "Amount exceeds total limit");
        }

        return (true, "");
    }

    /**
     * @dev Calculates next payment time
     */
    function getNextPaymentTime(uint256 lastPaymentTime, uint256 frequency, uint256 startTime)
        internal
        pure
        returns (uint256)
    {
        if (lastPaymentTime == 0) {
            return startTime;
        }
        return lastPaymentTime + frequency;
    }

    /**
     * @dev Calculates remaining payment capacity
     */
    function getRemainingCapacity(uint256 totalLimit, uint256 totalPaid) internal pure returns (uint256) {
        return totalLimit > totalPaid ? totalLimit - totalPaid : 0;
    }
}
