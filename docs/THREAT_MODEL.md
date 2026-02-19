# Threat Model

## Assets

- Token balances in vesting and supporter contracts
- Owner privileges and recipient update functions
- User locked principal and pending rewards

## Trust Assumptions

- Owner key is secure and operationally separated from deployer where possible.
- External token (if any) behaves as compliant ERC20.
- In Zarosabe flow, `LinearVesting` ownership is renounced after setup.
- `ZarosabeSupporter` validates upstream linkage (recipient and token) at emission start.
- Deployment and activation order in `README.md` is treated as mandatory; deviations are unsupported and out of threat-model scope.

## Key Risks

- Incorrect reward accounting causing over/under-distribution
- Access control misconfiguration
- Reentrancy around token transfer paths
- Unexpected behavior from non-standard ERC20 tokens
- Upstream configuration mismatch (wrong recipient/token linkage) blocks supporter emission start.
- If upstream ownership is not renounced, recipient can be redirected and break downstream assumptions.

## Required Tests

- Invariants for total distributed + remaining balance conservation
- Permission tests for owner-only methods
- Time-based vesting and emission boundary tests
- Reentrancy regression tests on claim/compound/unlock
