# Debyth Mandate Protocol

A comprehensive smart contract system for recurring stablecoin payments on Base network, inspired by traditional direct debit systems but with full user control and transparency.

## 🎯 Overview

The Debyth Mandate Protocol allows users to set up automatic, recurring stablecoin payments with complete control and transparency. Users create "mandates" that define payment rules, and authorized executors can trigger payments according to those rules.

### Key Features

- **User Control**: Users set all payment rules and can cancel anytime
- **Recurring Payments**: Automated payments based on user-defined schedules
- **Multiple Tokens**: Support for USDC and USDT on Base
- **Upgradeable**: UUPS proxy pattern for future improvements
- **Factory Pattern**: Deploy individual or shared mandate contracts
- **Security**: Role-based access control and emergency pause functionality

## 📋 Contract Architecture

### Core Contracts

1. **Mandate.sol** - Main mandate contract with all payment logic
2. **MandateFactory.sol** - Factory for deploying mandate contracts
3. **Libraries/MandateValidation.sol** - Validation logic library
4. **Interfaces/** - Contract interfaces for integration

### Key Components

```
Mandate
├── Mandate Management
│   ├── Create mandates with payment rules
│   ├── Cancel mandates
│   └── Query mandate status
├── Payment Execution
│   ├── Executor-triggered payments
│   ├── Validation checks
│   └── Balance/allowance verification
└── Admin Functions
    ├── Executor management
    ├── Token support
    └── Emergency controls
```

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

3. **Approve tokens:**
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
- Comprehensive input validation
- Reentrancy protection via OpenZeppelin
- Custom errors for gas efficiency

### Upgrade Safety
- UUPS proxy pattern
- Storage layout preservation
- Admin-controlled upgrades

## 📊 Gas Optimization

The contracts are optimized for gas efficiency:

- Custom errors instead of require strings
- Efficient storage packing
- Minimal external calls
- Batch operations where possible

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

Monitor events for payment execution:

```javascript
const mandateContract = new ethers.Contract(address, abi, provider);

mandateContract.on("PaymentExecuted", (mandateId, payer, payee, token, amount, timestamp) => {
    // Handle payment execution
});
```

## 📈 Roadmap

- [ ] Multi-chain deployment (Ethereum, Polygon, Arbitrum)
- [ ] Additional stablecoin support (DAI, FRAX)
- [ ] Batch payment execution
- [ ] Payment scheduling improvements
- [ ] Integration with DeFi protocols

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

Built with ❤️ for the future of recurring payments on Base.
