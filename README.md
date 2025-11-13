## P2P Lending Matching Engine

Superlend is an experimental liquidity matching engine that pairs token lenders and borrowers and pipes idle liquidity into an Aave v3 reserve. The system is implemented in Solidity and tested with Foundry.

- Lenders post principal at a minimum acceptable rate; funds are auto-supplied to Aave until paired.
- Borrowers submit requests with a maximum rate; when a compatible lender exists the engine settles on a midpoint rate.
- Active loans accrue simple interest prorated by elapsed time; borrowers repay principal plus interest back to the contract.
- Lenders can cancel orders to withdraw their remaining principal plus a pro-rata share of any accrued Aave yield.

## Repository Layout

- `src/MatchingEngine.sol` – core order book, matching logic, loan accounting, and Aave integrations.
- `src/interfaces/IAaveV3Pool.sol` – lightweight interface subset required for supply/withdraw calls.
- `test/MatchingEngine.t.sol` – Foundry test suite covering matching scenarios, cancellations, and repayment.
- `lib/` – vendored dependencies (`forge-std`, `openzeppelin-contracts`) used during compilation and testing.
- `foundry.toml` – Foundry project configuration (solc version, optimizer settings, remappings).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) toolchain (`forge`, `cast`, `anvil`). Install with `curl -L https://foundry.paradigm.xyz | bash` followed by `foundryup`.
- Recent Node.js is optional, only required if you want to regenerate OpenZeppelin artifacts or tooling scripts.

## Getting Started

```shell
# Install dependencies (only required if lib/ is not yet populated)
forge install

# Compile all contracts
forge build
```

## Running Tests

```shell
forge test
```

The suite uses in-memory mocks for the ERC20 reserve and Aave pool so it runs deterministically without chain forking. Gas reports can be produced with `forge test --gas-report`.

## Key Concepts

- **Bucketed Order Books**: Orders are grouped by 25 bps rate increments. Bitmaps track the highest priority buckets for O(1) lookup.
- **Midpoint Pricing**: When matching, borrower and lender rates are averaged to determine the loan rate, ensuring both sides satisfy their thresholds.
- **Idle Liquidity Management**: Unmatched lender liquidity is continuously supplied to Aave. Yield is accounted for when lenders cancel.
- **Simple Interest Loans**: Loans accrue simple interest based on rate (basis points) and elapsed time (`calculateDebt`).

## Scripts and Deployment

No deployment scripts are packaged yet. To experiment on a local Anvil chain:

```shell
anvil &
forge script <your-script> --rpc-url http://127.0.0.1:8545 --broadcast
```

You will need to provide addresses for the reserve asset and the target Aave pool (or mocks) when deploying `MatchingEngine`.

## Contributing

- Run `forge fmt` before submitting changes.
- Add or update Foundry tests in `test/` to demonstrate new behavior.
- Document non-trivial behavior directly in the contract or README to keep contributors aligned.

## License

The contracts are released under the MIT License. See the SPDX identifiers in each Solidity source file for details.
