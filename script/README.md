# Scripts

Add Foundry scripts in this folder using `*.s.sol` naming.

## Included scripts

- `DeployAndSetup.s.sol`
- `StartSupporterEmission.s.sol`

## Env vars

- `PRIVATE_KEY`
- `MARKET_RECIPIENT`
- `BADGE_ROOT_URI`
- `SUPPORTER_ADDRESS` (used by start script)

## Run examples

```bash
forge script script/DeployAndSetup.s.sol:DeployAndSetupScript --rpc-url $SEPOLIA_RPC_URL --broadcast
forge script script/StartSupporterEmission.s.sol:StartSupporterEmissionScript --rpc-url $SEPOLIA_RPC_URL --broadcast
```
