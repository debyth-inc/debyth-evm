// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Mandate.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MandateFactory
 * @dev Factory contract for deploying mandate contracts using clones
 */
contract MandateFactory is Ownable {
    address public immutable mandateImplementation;

    mapping(address => address[]) public userMandateContracts;
    address[] public allMandateContracts;

    event MandateContractDeployed(address indexed deployer, address indexed mandateContract, address[] supportedTokens);

    constructor(address _mandateImplementation) Ownable(msg.sender) {
        mandateImplementation = _mandateImplementation;
    }

    /**
     * @dev Deploys a new mandate contract for a user using clones
     */
    function deployMandateContract(address[] memory supportedTokens) external returns (address) {
        address clone = Clones.clone(mandateImplementation);

        // Initialize the clone
        Mandate(clone).initialize(msg.sender, supportedTokens);

        userMandateContracts[msg.sender].push(clone);
        allMandateContracts.push(clone);

        emit MandateContractDeployed(msg.sender, clone, supportedTokens);

        return clone;
    }

    /**
     * @dev Gets all mandate contracts for a user
     */
    function getUserMandateContracts(address user) external view returns (address[] memory) {
        return userMandateContracts[user];
    }

    /**
     * @dev Gets total number of deployed mandate contracts
     */
    function getTotalMandateContracts() external view returns (uint256) {
        return allMandateContracts.length;
    }

    /**
     * @dev Gets mandate contract at index
     */
    function getMandateContractAt(uint256 index) external view returns (address) {
        require(index < allMandateContracts.length, "Index out of bounds");
        return allMandateContracts[index];
    }
}
