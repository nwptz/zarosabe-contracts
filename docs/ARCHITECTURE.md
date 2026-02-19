# Architecture

## Contracts

- `TokenSample`: fixed-supply ERC20 that mints market allocation to recipient and vesting allocation to itself, then transfers vesting once via `initializeVesting`.
- `LinearVesting`: composable linear vesting source contract with owner-managed recipient until renounced.
- `ZarosabeSupporter`: Zarosabe-specific supporter lock pool with SBT badge logic and emissions.

## Design Notes

- Keep token minting and vesting responsibilities explicit and minimal.
- Use events for all state transitions affecting balances and permissions.
- Separate user principal from rewards accounting in staking logic.
- `ZarosabeSupporter` depends on `LinearVesting` as upstream liquidity source.
- For Zarosabe trust model, `LinearVesting` ownership must be renounced after setup.

## Deployment Sequence (Zarosabe Flow)

1. Deploy `TokenSample` with market recipient.
2. Deploy `LinearVesting` with `TokenSample` address.
3. Deploy `ZarosabeSupporter` with `TokenSample` and `LinearVesting` addresses.
4. Set `LinearVesting.vestingRecipient` to `ZarosabeSupporter`.
5. Call `TokenSample.initializeVesting(LinearVesting)`.
6. Start `LinearVesting`.
7. Renounce `LinearVesting` ownership.
8. Open fair-launch lock window in `ZarosabeSupporter`.
9. Start `ZarosabeSupporter` emission.

## Interface Freeze

- `TokenSample.constructor(address)` is the only constructor entrypoint.
- Vesting transfer is post-deploy via `TokenSample.initializeVesting(address)`.
- `LinearVesting` recipient linkage is finalized operationally via deployment sequence.
- `ZarosabeSupporter.startEmission()` is the single activation gate for upstream linkage checks.

## To Complete

- Add sequence diagrams for lock/claim/compound flows.
- Add invariant list for formal and fuzz testing.
- Document trusted roles and irreversible operations.
