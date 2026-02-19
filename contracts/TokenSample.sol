// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TokenSample
/// @notice Fixed-supply ERC20 with EIP-2612 permit and user burn functionality.
/// @dev
/// - Total supply is minted once at deployment.
/// - No further minting path exists.
/// - Vesting allocation is initially held by this contract.
/// - Owner performs one-time vesting initialization to transfer allocation to vesting contract.
/// - This two-phase setup avoids deployment circular dependency between token and vesting.
contract TokenSample is ERC20, ERC20Permit, Ownable {
    /// @notice Total fixed token supply minted at deployment.
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000e18;
    /// @notice Portion of supply allocated to market distribution.
    uint256 public constant COIN_MARKET_SUPPLY = 50_000_000_000e18;
    /// @notice Portion of supply allocated to vesting contract.
    uint256 public constant VESTING_SUPPLY = TOTAL_SUPPLY - COIN_MARKET_SUPPLY;

    /// @notice Reverts when a required address input is zero.
    error ZeroAddress();
    /// @notice Reverts when vesting initialization is attempted more than once.
    error VestingAlreadyInitialized();

    /// @notice Whether vesting allocation has been initialized and transferred out.
    bool public vestingInitialized;

    /// @notice Emitted once during deployment for initial fixed supply distribution.
    /// @param marketRecipient Recipient of market allocation.
    /// @param marketAmount Amount minted to market recipient.
    /// @param vestingAmount Amount minted to this token contract for later vesting initialization.
    event InitialDistribution(
        address indexed marketRecipient,
        uint256 marketAmount,
        uint256 vestingAmount
    );
    /// @notice Emitted when one-time vesting allocation is transferred to vesting recipient.
    /// @param vestingRecipient Recipient of vesting allocation.
    /// @param vestingAmount Amount transferred for vesting.
    event VestingInitialized(address indexed vestingRecipient, uint256 vestingAmount);

    /**
     * @notice Deploys token and performs initial fixed supply split.
     * @param marketRecipient Address that receives market allocation.
     * @dev Reverts with {ZeroAddress} if `marketRecipient` is zero address.
     * @dev Market allocation is minted to `marketRecipient`.
     * @dev Vesting allocation is minted to this contract and transferred later via {initializeVesting}.
     */
    constructor(
        address marketRecipient
    ) ERC20("TokenSample", "TKNSMPL") ERC20Permit("TokenSample") Ownable(msg.sender) {
        if (marketRecipient == address(0)) revert ZeroAddress();

        _mint(marketRecipient, COIN_MARKET_SUPPLY);
        _mint(address(this), VESTING_SUPPLY);

        emit InitialDistribution(marketRecipient, COIN_MARKET_SUPPLY, VESTING_SUPPLY);
    }

    /**
     * @notice Transfers one-time vesting allocation to vesting recipient.
     * @param vestingRecipient Address that receives full vesting allocation.
     * @dev Callable only by owner and only once.
     * @dev Reverts with {ZeroAddress} when recipient is zero address.
     * @dev Reverts with {VestingAlreadyInitialized} if already initialized.
     */
    function initializeVesting(address vestingRecipient) external onlyOwner {
        if (vestingRecipient == address(0)) revert ZeroAddress();
        if (vestingInitialized) revert VestingAlreadyInitialized();

        vestingInitialized = true;
        _transfer(address(this), vestingRecipient, VESTING_SUPPLY);

        emit VestingInitialized(vestingRecipient, VESTING_SUPPLY);
    }

    /**
     * @notice Burns caller tokens and reduces total supply.
     * @param amount Amount of tokens to burn.
     * @dev Reverts if caller balance is below `amount`.
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
