# Zarosabe Contracts

Professional baseline repository for the Zarosabe smart contract suite.

## Contracts

- `contracts/TokenSample.sol`
- `contracts/LinearVesting.sol`
- `contracts/ZarosabeSupporter.sol`

## Stack

- Solidity `^0.8.28`
- Foundry (build/test/script)
- OpenZeppelin Contracts
- Solhint + Prettier (Solidity formatting/linting)
- GitHub Actions CI

## Quick Start

### 1. Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 20+

### 2. Install dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
npm install
```

### 3. Build and test

```bash
forge build
forge test -vv
```

### 4. Lint and format check

```bash
npm run lint
npm run format:check
```

## Repository Layout

- `contracts/` Solidity source files
- `test/` Foundry tests
- `script/` deployment/ops scripts
- `docs/` architecture, tokenomics, threat model
- `audit/` security review notes and remediations

## Security Workflow

- No private keys in repository
- Use `.env` from `.env.example`
- Run static analysis and tests before any deploy
- Require CI checks on pull requests

## Zarosabe Deployment Runbook

1. Deploy `TokenSample` with `marketRecipient`.
2. Deploy `LinearVesting` with `token = TokenSample` and optional initial recipient.
3. Deploy `ZarosabeSupporter` with `token = TokenSample` and `upstream = LinearVesting`.
4. Set `LinearVesting.vestingRecipient` to `ZarosabeSupporter`.
5. Call `TokenSample.initializeVesting(LinearVesting)` to transfer vesting allocation.
6. Start `LinearVesting` emission.
7. Renounce `LinearVesting` ownership (MUST for Zarosabe trust model).
8. Allow fair-launch lock window in `ZarosabeSupporter` (users can lock before supporter emission starts).
9. Start `ZarosabeSupporter` emission.

## API Freeze (Pre Script/Test)

- `TokenSample`:
- `constructor(address marketRecipient)`
- `initializeVesting(address vestingRecipient)` (owner-only, one-time)
- `burn(uint256 amount)`
- `LinearVesting`:
- `constructor(address token_, address initialRecipient_)`
- `setVestingRecipient(address newRecipient)` (owner-only)
- `startEmission()` (owner-only)
- `claimVesting()` (permissionless trigger)
- `ZarosabeSupporter`:
- `constructor(address _zarosabe, address _upstream, string badgeRootURI)`
- `startEmission()` (owner-only)
- `lock(uint256 amount)`, `claim()`, `compound()`, `unlock()`, `migratePosition(address newWallet)`
- `retrieveToken(address token)` (owner-only)
- Deployment/order assumptions in this README are treated as locked for script/test work.

## ZarosabeSupporter Migration Notes

- `migratePosition(address newWallet)` moves full live position ownership to `newWallet`:
- lock state (`lockedBalance`)
- reward accounting (`pendingRewards`, `userRewardPerTokenPaid`)
- badge history (`badgeLockedAmount`)
- active SBT ownership (burn old SBT, mint new SBT with new tokenId)
- Migration is allowed any time, including after emission end and after unlock (badge/history-only migration).
- SBT cannot be transferred wallet-to-wallet.
- SBT burn is disallowed unless called internally by migration flow.
- `supporterCount` tracks unique supporter wallets currently holding a live SBT (one SBT per wallet at a time).

## License

MIT
