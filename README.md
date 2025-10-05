# Debyth Mandate Protocol

A comprehensive smart contract system for recurring stablecoin payments on Base network with intelligent approval management. Combines the convenience of traditional direct debits with complete user control and proactive monitoring.

## 🎯 Overview

The Debyth Mandate Protocol enables automated recurring stablecoin payments while solving the approval management problem. Users maintain full control over their funds while the system provides intelligent monitoring, predictive alerts, and automated safety mechanisms.

### Key Features

- **Intelligent Approval Management**: Automated monitoring with predictive alerts
- **User Sovereignty**: Complete control over funds with instant exit options
- **Recurring Payments**: Automated payments based on user-defined schedules
- **Proactive Monitoring**: Health checks prevent payment failures
- **Clone Architecture**: Gas-efficient deployment using minimal clones
- **Multiple Tokens**: Support for USDC and USDT on Base
- **Auto-Pause Protection**: System pauses mandates when allowance is critically low
- **Configurable Thresholds**: Users set their own warning and critical levels

## 📋 Contract Architecture

### Core Contracts

1. **Mandate.sol** - Main mandate contract with payment logic and approval health monitoring
2. **MandateFactory.sol** - Factory for deploying mandate clones
3. **Libraries/MandateValidation.sol** - Validation logic library
4. **Interfaces/** - Contract interfaces for integration

### Architecture Overview

```
Mandate System
├── Core Mandate Logic
│   ├── Create/cancel mandates
│   ├── Execute payments with validation
│   └── Role-based access control
├── Intelligent Approval Management
│   ├── Health monitoring after each payment
│   ├── Configurable warning thresholds
│   ├── Auto-pause on critical allowance
│   └── Smart top-up recommendations
├── Clone Deployment
│   ├── Gas-efficient user instances
│   ├── Factory-based deployment
│   └── Isolated contract state
└── Event-Driven Integration
    ├── Real-time health alerts
    ├── Payment notifications
    └── System status updates
```

### 🧠 Intelligent Approval Management

The protocol's key innovation solves the approval management problem:

**The Problem:**
- Infinite approvals are security risks users avoid
- Exact approvals require frequent re-approvals
- Manual management leads to failed payments

**Our Solution:**
- **Predictive Monitoring**: Tracks remaining payments vs current allowance
- **Configurable Alerts**: Users set warning (default: 3 payments) and critical (default: 1 payment) thresholds  
- **Auto-Pause Protection**: Automatically pauses mandates when allowance is critically low
- **Smart Recommendations**: Calculates optimal top-up amounts with 10% buffer
- **User Control**: Adjust thresholds, disable auto-pause, unpause anytime

**Benefits:**
- ✅ No infinite approvals needed
- ✅ Proactive failure prevention  
- ✅ Optimal user experience
- ✅ Complete user sovereignty

## 🚀 Quick Start

### Installation

```bash
# Install dependencies (requires manual installation)
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable

# Build contracts
forge build

# Run tests
forge test
```

### Basic Usage

1. **Deploy the system:**
```bash
forge script script/DeployMandate.s.sol --rpc-url base --private-key $PRIVATE_KEY --broadcast
```

2. **Create a mandate:**
```solidity
uint256 mandateId = mandate.createMandate(
    payeeAddress,        // Who receives payments
    usdcAddress,         // Token to pay with
    1000e6,             // Total limit (1000 USDC)
    100e6,              // Per payment limit (100 USDC)
    30 days,            // Payment frequency
    block.timestamp,     // Start time
    block.timestamp + 365 days  // End time
);
```

3. **Get smart approval recommendation:**
```solidity
uint256 recommended = mandate.calculateRecommendedTopUp(mandateId, 6); // 6 payments ahead
```

4. **Approve tokens with recommended amount:**
```solidity
IERC20(usdcAddress).approve(mandateContract, recommended);
```

5. **Monitor approval health:**
```solidity
(uint256 allowance, uint256 remaining, uint256 topUp, bool healthy) = 
    mandate.getApprovalHealth(mandateId);
```

6. **Execute payments (by authorized executor):**
```solidity
mandate.executePayment(mandateId, 100e6); // Automatically checks health
```

### Approval Health Events

Listen for these events to build responsive UIs:

```solidity
// Warning: allowance getting low
event ApprovalLowWarning(uint256 indexed mandateId, uint256 remainingAllowance, 
                        uint256 paymentsRemaining, uint256 recommendedTopUp);

// Critical: mandate will auto-pause soon  
event ApprovalCritical(uint256 indexed mandateId, uint256 remainingAllowance, 
                      uint256 recommendedTopUp);

// System paused mandate for protection
event MandateAutoPaused(uint256 indexed mandateId, string reason);

// Smart recommendation for top-up
event ApprovalTopUpRequested(uint256 indexed mandateId, uint256 recommendedAmount, 
                            uint256 forPayments);
```

### User Control Functions

```solidity
// Customize warning thresholds
mandate.setApprovalThresholds(mandateId, 5, 2); // warn at 5, pause at 2

// Enable/disable auto-pause
mandate.setAutoPause(mandateId, true);

// Unpause after topping up allowance
mandate.unpauseMandate(mandateId);

// Emergency stop
mandate.cancelMandate(mandateId);
```
```solidity
IERC20(usdcAddress).approve(mandateContract, 1000e6);
```

4. **Execute payments (by authorized executor):**
```solidity
mandate.executePayment(mandateId, 100e6);
```

## 📖 Detailed Usage

### Creating Mandates

Users create mandates by calling `createMandate()` with these parameters:

- `payee`: Address to receive payments
- `token`: USDC or USDT address
- `totalLimit`: Maximum total amount payable
- `perPaymentLimit`: Maximum per payment
- `frequency`: Time between payments (seconds)
- `startTime`: When payments can begin
- `endTime`: When mandate expires

### Payment Execution

Only authorized executors can trigger payments via `executePayment()`. The contract validates:

- Mandate is active and not expired
- Payment timing (frequency constraints)
- Amount limits (per payment and total)
- User has sufficient balance and allowance

### User Control

Users maintain full control:

- **Cancel anytime**: Call `cancelMandate()`
- **Revoke permissions**: Set token allowance to 0
- **Monitor activity**: All actions emit events

## 🧪 Testing

Comprehensive test suite covering:

```bash
# Run all tests
forge test

# Run specific test files
forge test --match-path test/Mandate.t.sol
forge test --match-path test/MandateIntegration.t.sol

# Run with gas reporting
forge test --gas-report
```

### Test Coverage

- ✅ Mandate creation and validation
- ✅ Payment execution and constraints  
- ✅ Approval health monitoring and alerts
- ✅ Auto-pause and unpause functionality
- ✅ Smart top-up recommendations
- ✅ User threshold configuration
- ✅ User cancellation and revocation
- ✅ Admin functions and access control
- ✅ Factory deployment patterns
- ✅ Integration workflows
- ✅ Edge cases and error conditions

## 🔧 Configuration

### Supported Tokens (Base Network)

- **USDC**: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- **USDT**: `0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2`

### Environment Variables

```bash
# For deployment
PRIVATE_KEY=your_private_key
RPC_URL=https://mainnet.base.org
```

## 🔐 Security Features

### Access Control
- **Admin Role**: Contract upgrades, executor management
- **Executor Role**: Payment execution only
- **User Control**: Mandate creation, cancellation

### Safety Mechanisms
- Pausable contract for emergencies
- Auto-pause on critical allowance levels
- Comprehensive input validation
- Reentrancy protection via OpenZeppelin
- Custom errors for gas efficiency
- Predictive failure prevention

### Architecture Benefits
- Clone pattern for gas efficiency
- Isolated user contract instances
- Event-driven monitoring integration
- Modular approval health system

## 📊 Gas Optimization

The contracts are optimized for gas efficiency:

- **Clone pattern**: ~90% gas savings vs proxy deployment
- **Struct separation**: Avoids "stack too deep" compilation errors
- **Function splitting**: Reduces complexity and gas costs
- **Custom errors**: Gas-efficient error handling
- **Efficient storage**: Packed structs and optimized mappings
- **Piggyback monitoring**: Health checks during payment execution

### Typical Gas Costs
- Deploy clone: ~100k gas
- Create mandate: ~150k gas  
- Execute payment: ~80k gas
- Health check: ~20k gas (included in payment)

## 🤝 Integration

### For DApps

```solidity
import "./interfaces/IMandateRegistry.sol";

contract YourContract {
    IMandateRegistry public mandate;
    
    function setupRecurringPayment() external {
        uint256 mandateId = mandate.createMandate(
            // ... parameters
        );
        // Handle mandate creation
    }
}
```

### For Backend Services

Monitor events for comprehensive automation:

```javascript
const mandateContract = new ethers.Contract(address, abi, provider);

// Payment monitoring
mandateContract.on("PaymentExecuted", (mandateId, payer, payee, token, amount, timestamp) => {
    console.log(`Payment executed: ${amount} tokens`);
});

// Approval health monitoring
mandateContract.on("ApprovalLowWarning", (mandateId, remaining, paymentsLeft, recommended) => {
    notifyUser(mandateId, `Warning: ${paymentsLeft} payments remaining. Top up with ${recommended} tokens.`);
});

mandateContract.on("ApprovalCritical", (mandateId, remaining, recommended) => {
    alertUser(mandateId, `Critical: Top up with ${recommended} tokens to avoid auto-pause.`);
});

mandateContract.on("MandateAutoPaused", (mandateId, reason) => {
    notifyUser(mandateId, `Mandate paused: ${reason}. Please top up and unpause.`);
});
```

## 📈 Roadmap

- [ ] Multi-chain deployment (Ethereum, Polygon, Arbitrum)
- [ ] Additional stablecoin support (DAI, FRAX)
- [ ] Advanced approval strategies (time-based, dynamic thresholds)
- [ ] Batch payment execution
- [ ] Payment scheduling improvements
- [ ] Integration with DeFi protocols
- [ ] Mobile SDK for approval management
- [ ] Analytics dashboard for payment patterns

## 📚 Documentation

- **[MANDATE_FLOW.md](./MANDATE_FLOW.md)** - Detailed contract flow and design decisions
- **[Contract Documentation](./src/)** - Inline code documentation
- **[Test Examples](./test/)** - Comprehensive test scenarios

## 🛠 Development

### Project Structure

```
src/
├── Mandate.sol          # Main mandate contract
├── MandateFactory.sol          # Factory contract
├── interfaces/                 # Contract interfaces
│   ├── IMandateRegistry.sol
│   └── IExecutorManager.sol
└── libraries/                  # Utility libraries
    └── MandateValidation.sol

test/
├── Mandate.t.sol        # Core contract tests
├── MandateFactory.t.sol        # Factory tests
└── MandateIntegration.t.sol    # Integration tests

script/
└── DeployMandate.s.sol  # Deployment script
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details.

## 🔗 Links

- [Base Network](https://base.org/)
- [OpenZeppelin Contracts](https://openzeppelin.com/contracts/)
- [Foundry Documentation](https://book.getfoundry.sh/)

---
