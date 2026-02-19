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

## Runtime Flows

- `lock(amount)`:
- User transfers principal into `ZarosabeSupporter`.
- First lock mints one soulbound badge and increments supporter count.
- Rewards are checkpointed before lock-state mutation.
- `_pullUpstream()` may claim from `LinearVesting` to top up pool liquidity.

- `claim()`:
- User checkpoints rewards, burn schedule is applied to gross reward.
- Contract enforces liquid reward sufficiency via `_ensureRewardBalance`.
- Burned amount is destroyed via `TokenSample.burn`, net amount is transferred.

- `compound()`:
- Same reward checkpointing as claim, but no burn path.
- Reward is re-locked directly as principal in the same position.
- Requires minimum reward threshold to avoid dust compounding.

- `unlock()`:
- Only after global `emissionEnd`.
- Claims pending reward first (burn effectively 0% post-end), then returns principal.
- Lock balance is zeroed and `totalLocked` reduced before transfer.

## Trusted Roles And Irreversible Operations

- `TokenSample` owner:
- Calls one-time `initializeVesting(address)` to move vesting allocation.
- No mint path after deployment.

- `LinearVesting` owner:
- Sets recipient, starts emission, then renounces ownership for Zarosabe trust model.
- After renounce, recipient can no longer be changed.

- `ZarosabeSupporter` owner:
- Starts supporter emission once.
- Can recover non-Zarosabe tokens via `retrieveToken(address)`.
- Should be renounced per project governance decision after setup.

## Security Invariants

- Token supply split is fixed at deployment:
- `market + vesting == TOTAL_SUPPLY`.

- `LinearVesting` claim conservation:
- `totalClaimed <= VESTING_SUPPLY`.
- `getClaimableAmount()` is monotonic with time and bounded by remaining vesting.

- `ZarosabeSupporter` principal separation:
- `totalLocked` tracks only user principal plus compounded rewards.
- `remainingClaimablePool()` excludes `totalLocked` from withdrawable rewards.

- Upstream linkage constraints:
- At supporter `startEmission`, upstream must already be started.
- Upstream recipient must equal supporter address.
- Upstream token must equal Zarosabe token.
