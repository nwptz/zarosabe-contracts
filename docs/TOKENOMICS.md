# Tokenomics

## Supply

- Total supply: `100,000,000,000` tokens (18 decimals).
- Fixed split at deployment:
- Market allocation: `50,000,000,000`.
- Vesting allocation: `50,000,000,000`.
- No post-deployment mint function exists.

## Distribution

- At `TokenSample` deploy:
- `50B` minted to `marketRecipient`.
- `50B` minted to `TokenSample` itself as pending vesting allocation.

- One-time initialization:
- Owner calls `initializeVesting(linearVesting)` to transfer the full `50B` vesting allocation.
- Function is single-use and cannot be called twice.

- Linear vesting stream:
- `LinearVesting` emits `50B` over `5 * 365 days` (1825 days).
- Claims are permissionless and always transfer to current `vestingRecipient`.

## Emissions

- `ZarosabeSupporter` target reward budget: `50B` over `5 * 365 days`.
- Emission clock is local to supporter contract and starts on `startEmission()`.
- Reward liquidity source is upstream `LinearVesting` claims.

- Claim burn schedule (by elapsed time since supporter emission start):
- Year 1: `40%`
- Year 2: `30%`
- Year 3: `20%`
- Year 4: `10%`
- Year 5: `5%`
- After year 5: `0%`

- `compound()` path:
- No burn applied.
- Claimed reward is re-locked as principal.

- Lock semantics:
- Users may lock before supporter emission starts (fair-launch window).
- Principal unlock is globally allowed only after supporter emission end.
