# Tokenomics

## Supply

- Total supply and vesting constants are defined on-chain in contract source.

## Distribution

- Market allocation is sent to market recipient at deployment.
- Vesting allocation is minted to `TokenSample` and transferred once via `initializeVesting`.
- Vesting unlocks linearly over configured duration.

## Emissions

- Supporter rewards are emitted over fixed duration.
- Burn penalty and compounding behavior are encoded in pool logic.
- Supporter emission budget is sourced from upstream `LinearVesting`.

## To Complete

- Fill exact percentages and recipient addresses.
- Add treasury, liquidity, and vesting policy rationale.
