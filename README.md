# Credit Protocol - Move Migration CTRL + MOVE HACKATHON

This directory contains the Credit Protocol smart contracts Move (Aptos).

## Architecture

The protocol consists of 5 main modules:

### 1. Interest Rate Model (`interest_rate_model.move`)
- Manages interest rate calculations (fixed and dynamic rates)
- Handles grace periods and interest accrual
- Supports both time-based and utilization-based rate models

### 2. Lending Pool (`lending_pool.move`)
- Manages liquidity deposits and withdrawals from lenders
- Handles borrowing and repayment flows
- Distributes interest to lenders and collects protocol fees
- Tracks utilization rates

### 3. Collateral Vault (`collateral_vault.move`)
- Manages borrower collateral deposits
- Handles collateral locking/unlocking
- Supports liquidation mechanisms
- Tracks collateral status (Active, Locked, Liquidating)

### 4. Reputation Manager (`reputation_manager.move`)
- Tracks borrower credit scores and payment history
- Manages reputation tiers (Bronze, Silver, Gold, Platinum)
- Records defaults and payment behavior
- Updates scores based on repayment patterns

### 5. Credit Manager (`credit_manager.move`)
- Core orchestration layer
- Manages credit line creation and management
- Handles borrowing, repayment, and liquidation logic
- Integrates with all other modules
- Manages credit limit increases based on reputation

## Key Features

### Move-Specific Improvements
- **Resource-based Architecture**: Uses Move's resource model for better safety
- **Event System**: Comprehensive event emission for all major actions
- **Access Control**: Granular permission system using Move's safety features
- **Error Handling**: Detailed error codes and assertions
- **Gas Efficiency**: Optimized for Aptos transaction costs

### Protocol Features
- **Overcollateralized Lending**: Users deposit collateral to borrow
- **Dynamic Interest Rates**: Rates adjust based on pool utilization
- **Reputation System**: Credit scores improve with good payment history
- **Automated Liquidations**: Protocol automatically liquidates unhealthy positions
- **Protocol Fees**: Built-in fee mechanism for sustainability

## Deployment

1. **Compile the contracts:**
```bash
aptos move compile --dev
```

2. **Deploy using the deployment script:**
```bash
aptos move run --function-id 0x42::deploy::deploy_credit_protocol --args address:YOUR_ADDRESS
```

3. **Initialize individual modules if needed:**
```bash
# Initialize Interest Rate Model
aptos move run --function-id 0x42::interest_rate_model::initialize --args address:ADMIN address:CREDIT_MANAGER

# Initialize other modules similarly...
```

## Usage

### For Lenders
1. **Deposit funds:** Call `lending_pool::deposit()`
2. **Earn interest:** Interest is distributed automatically
3. **Withdraw:** Call `lending_pool::withdraw()`

### For Borrowers
1. **Open credit line:** Call `credit_manager::open_credit_line()` with collateral
2. **Borrow funds:** Call `credit_manager::borrow()` up to credit limit
3. **Repay loan:** Call `credit_manager::repay()` with principal and interest
4. **Build reputation:** Make on-time payments to improve credit score

### For Administrators
- **Pause/unpause** any module for emergency stops
- **Update parameters** like interest rates and collateral ratios
- **Liquidate** unhealthy positions
- **Withdraw protocol fees**

## Module Interactions

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│  Interest Rate  │    │   Reputation     │    │  Collateral     │
│     Model       │    │    Manager       │    │     Vault       │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────┐
                    │  Credit Manager │  ←─────────────────┐
                    │   (Orchestrator) │                    │
                    └─────────────────┘                    │
                                 │                         │
                    ┌─────────────────┐                    │
                    │  Lending Pool   │ ───────────────────┘
                    │   (Liquidity)   │
                    └─────────────────┘
```

## Security Features

- **Reentrancy Protection**: Move's resource model prevents reentrancy attacks
- **Access Control**: Role-based permissions for sensitive operations
- **Pausable**: Emergency stop functionality in all modules
- **Parameter Validation**: Comprehensive input validation
- **Safe Math**: Move's built-in overflow protection

## Testing

Create test files in `tests/` directory:

```move
#[test_only]
module credit_protocol::test_credit_manager {
    use credit_protocol::credit_manager;
    // Add test functions here
}
```

Run tests:
```bash
aptos move test
```

## Differences from Solidity Version

### Technical Differences
- **No Upgradeable Contracts**: Move uses a different upgrade pattern
- **Resource Model**: Assets are represented as resources, not mappings
- **Event System**: Events are emitted using Move's native event system
- **Error Handling**: Uses Move's `error` module instead of `require` statements

### Token Differences
- **AptosCoin Usage**: Currently uses AptosCoin as placeholder for USDC
- **Coin Standard**: Uses Aptos Coin standard instead of ERC-20
- **Native Integration**: Better integration with Aptos native features

### Gas Optimization
- **Batch Operations**: More efficient batch processing
- **Resource Efficiency**: Move's resource model reduces storage costs
- **Parallel Execution**: Aptos supports parallel transaction execution

## Configuration

Key parameters can be configured:
- Interest rates (base, max, penalty)
- Grace periods
- Collateralization ratios
- Reputation scoring parameters
- Protocol fee rates

## Future Enhancements

- **Multi-Asset Support**: Support for multiple collateral types
- **Flash Loans**: Add flash loan functionality
- **Governance**: Decentralized parameter management
- **Oracle Integration**: External price feeds for collateral valuation
- **Cross-Chain**: Bridge functionality for multi-chain lending

## Support

For questions or issues:
1. Check the test files for usage examples
2. Review the inline documentation in each module
3. Examine the event structures for debugging

This migration maintains all the core functionality of the original Solidity contracts while leveraging Move's unique features for enhanced security and efficiency.
