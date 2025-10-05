// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IExecutorManager
 * @dev Interface for managing payment executors
 */
interface IExecutorManager {
    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event ExecutorStatusChanged(address indexed executor, bool status);

    function addExecutor(address executor) external;
    function removeExecutor(address executor) external;
    function isExecutor(address account) external view returns (bool);
    function getExecutors() external view returns (address[] memory);
}
