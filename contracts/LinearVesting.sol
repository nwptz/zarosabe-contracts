// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LinearVesting
/// @notice One-time activated linear vesting contract with immutable token and owner-managed recipient.
/// @dev
/// Composable flows:
/// 1. Treasury/self vesting: deploy and keep recipient as owner-controlled.
/// 2. Public-owned setup: set recipient to downstream public contract, then renounce ownership.
///
/// Design intent:
/// - Recipient can be updated by owner while ownership exists.
/// - Claims are permissionless to support keeper or downstream contract triggering.
/// - No rescue/backdoor paths are included by design.
/// - In Zarosabe flow, ownership is expected to be renounced after setup.
contract LinearVesting is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Token distributed by this vesting schedule.
    IERC20 public immutable VESTING_TOKEN;
    /// @notice Current vesting recipient address.
    address public vestingRecipient;

    /// @notice Total amount distributable over full schedule.
    uint256 public constant VESTING_SUPPLY = 50_000_000_000e18;
    /// @notice Vesting duration set to five years (1825 days).
    uint256 public constant VESTING_DURATION = (5 * 365 days);
    /// @notice Cumulative amount already distributed.
    uint256 public totalClaimed;
    /// @notice Timestamp when vesting starts, set once in {startEmission}.
    uint256 public vestingStartTime;
    /// @notice Timestamp when vesting ends (`vestingStartTime + VESTING_DURATION`).
    uint256 public vestingEndTime;
    /// @notice True once emission has been started by owner.
    bool public emissionStarted;

    /// @notice Reverts when token address is zero.
    error InvalidToken();
    /// @notice Reverts when recipient address is zero where not allowed.
    error InvalidRecipient();
    /// @notice Reverts if emission start is attempted more than once.
    error EmissionAlreadyStarted();
    /// @notice Reverts when claim is attempted before emission starts.
    error EmissionNotStarted();
    /// @notice Reverts when contract funding is below required vesting supply.
    error InsufficientFunding();

    /// @notice Emitted when vesting recipient is updated.
    /// @param previousRecipient Previous recipient address.
    /// @param newRecipient New recipient address.
    event VestingRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    /// @notice Emitted when vested tokens are transferred to current recipient.
    /// @param recipient Recipient address at the time of claim.
    /// @param claimAmount Amount transferred in this claim.
    /// @param totalClaimed Total cumulative claimed after transfer.
    /// @param vestingStartTime Schedule start timestamp.
    /// @param vestingEndTime Schedule end timestamp.
    event VestingClaimed(
        address indexed recipient,
        uint256 claimAmount,
        uint256 totalClaimed,
        uint256 vestingStartTime,
        uint256 vestingEndTime
    );

    /// @notice Emitted once when vesting schedule is activated.
    /// @param startTime Vesting start timestamp.
    /// @param endTime Vesting end timestamp.
    event EmissionStarted(uint256 startTime, uint256 endTime);

    /// @notice Initializes immutable vesting token and initial recipient.
    /// @param token_ ERC20 token address used for vesting distribution.
    /// @param initialRecipient_ Optional recipient override. If zero, defaults to deployer.
    /// @dev Reverts with {InvalidToken} when token is zero address.
    constructor(address token_, address initialRecipient_) Ownable(msg.sender) {
        if (token_ == address(0)) revert InvalidToken();

        VESTING_TOKEN = IERC20(token_);
        vestingRecipient = initialRecipient_ == address(0) ? msg.sender : initialRecipient_;
    }

    /// @notice Sets vesting recipient.
    /// @param newRecipient Recipient that receives all future claims.
    /// @dev
    /// - Callable by owner while ownership exists.
    /// - Owner can redirect recipient until ownership is renounced.
    function setVestingRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidRecipient();
        address previous = vestingRecipient;
        vestingRecipient = newRecipient;
        emit VestingRecipientUpdated(previous, newRecipient);
    }

    /**
     * @notice Starts the emission period.
     * @dev Callable only once by owner.
     * @dev Requires pre-funding with at least `VESTING_SUPPLY`.
     * @dev Emits {EmissionStarted}.
     * @dev In trust-minimized setups, ownership should be renounced after successful start.
     */
    function startEmission() external onlyOwner {
        if (emissionStarted) revert EmissionAlreadyStarted();
        if (VESTING_TOKEN.balanceOf(address(this)) < VESTING_SUPPLY) revert InsufficientFunding();

        emissionStarted = true;
        vestingStartTime = block.timestamp;
        vestingEndTime = vestingStartTime + VESTING_DURATION;

        emit EmissionStarted(vestingStartTime, vestingEndTime);
    }

    /// @notice Transfers currently claimable vested amount to current recipient.
    /// @return claimAmount Amount transferred in this call.
    /// @dev
    /// - Permissionless function: any caller can trigger distribution.
    /// - Funds are always transferred to `vestingRecipient`, never to `msg.sender`.
    /// - Returns `0` if no amount is currently claimable.
    function claimVesting() external returns (uint256) {
        if (!emissionStarted) revert EmissionNotStarted();
        uint256 claimAmount = getClaimableAmount();
        if (claimAmount == 0) return 0;

        totalClaimed += claimAmount;
        VESTING_TOKEN.safeTransfer(vestingRecipient, claimAmount);
        emit VestingClaimed(
            vestingRecipient,
            claimAmount,
            totalClaimed,
            vestingStartTime,
            vestingEndTime
        );
        return claimAmount;
    }

    /// @notice Returns currently claimable amount based on linear vesting schedule.
    /// @return Amount currently claimable.
    function getClaimableAmount() public view returns (uint256) {
        uint256 vested = _calculateVestedAmount(block.timestamp);
        return vested > totalClaimed ? vested - totalClaimed : 0;
    }

    /// @notice Computes total vested amount at a given timestamp.
    /// @param timestamp Timestamp to evaluate.
    /// @return Vested amount available by `timestamp` before subtracting prior claims.
    function _calculateVestedAmount(uint256 timestamp) internal view returns (uint256) {
        if (!emissionStarted) return 0;
        if (timestamp <= vestingStartTime) return 0;
        if (timestamp >= vestingEndTime) return VESTING_SUPPLY;

        uint256 elapsed = timestamp - vestingStartTime;
        return (VESTING_SUPPLY * elapsed) / VESTING_DURATION;
    }
}
