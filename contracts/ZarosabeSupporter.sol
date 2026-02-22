// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
    Zarosabe Vesting Pool with Soulbound Supporter Badge

	- Converts upstream linear vesting into supporter emissions.
	- Supports global fixed-time locking for a 5-year period.
	- Self-contained emissions: 50B tokens over 5 years from emissionStart.
	- Upstream vesting serves as a liquidity source, not a clock.
    - Single-token staking pool.
	- Soulbound badge is unique per wallet (non-transferable, migratable via burn+mint).
    - Amount based badge tier (peak-locked based).
	- Time-based burn penalty on reward claims (higher burn early).
	- No burn penalty for direct compound (as incentive).
    - Strict separation of locked principal and rewards via accounting.
    - No upgradeability, no governance, no admin fees.
*/

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/*//////////////////////////////////////////////////////////////
                        ZAROSABE INTERFACE
//////////////////////////////////////////////////////////////*/

/**
 * @title IZarosabeToken
 * @dev Interface for the ZAROSABE token.
 * Minimal token surface required by the supporter pool.
 */
interface IZarosabeToken {
    /// @notice Returns the token balance for an account.
    /// @param account Address to query.
    /// @return Token balance of `account`.
    function balanceOf(address account) external view returns (uint256);
    /// @notice Burns tokens from caller balance.
    /// @param amount Amount to burn.
    function burn(uint256 amount) external;
}

/**
 * @title IVestingUpstream
 * @dev Interface for the upstream vesting.
 * Linear vesting source for supporter reward liquidity.
 */
interface IVestingUpstream {
    /// @notice Claims currently vested amount from upstream vesting.
    /// @return claimAmount Amount transferred to vesting recipient.
    function claimVesting() external returns (uint256);
    /// @notice Returns cumulative amount already claimed from upstream.
    /// @return Total claimed amount.
    function totalClaimed() external view returns (uint256);
    /// @notice Returns whether upstream emission schedule has started.
    /// @return True if upstream emission is active.
    function emissionStarted() external view returns (bool);
    /// @notice Returns current upstream vesting recipient.
    /// @return Recipient address used by upstream claims.
    function vestingRecipient() external view returns (address);
    /// @notice Returns token used by upstream vesting.
    /// @return ERC20 token reference.
    // solhint-disable-next-line func-name-mixedcase
    function VESTING_TOKEN() external view returns (IERC20);
}

/*//////////////////////////////////////////////////////////////
				ZAROSABE VESTING POOL + SBT
//////////////////////////////////////////////////////////////*/

/// @title ZarosabeSupporter
/// @notice Zarosabe-specific supporter pool with lock-based rewards and soulbound badge tiers.
/// @dev
/// Deployment and trust assumptions for this contract:
/// 1. `LinearVesting` MUST be configured to use this contract as `vestingRecipient`.
/// 2. `LinearVesting` MUST be started before this contract starts emissions.
/// 3. For trust minimization in Zarosabe flow, `LinearVesting` ownership MUST be renounced after setup.
/// @custom:security This contract is intentionally project-specific and not designed as a generic staking primitive.
/// @custom:security Upstream linkage is enforced at `startEmission`; wrong linkage blocks activation.
contract ZarosabeSupporter is Ownable, ReentrancyGuard, ERC721 {
    using SafeERC20 for IERC20;

    /// @notice Reverts when Zarosabe token address is zero.
    error ZeroZarosabe();
    /// @notice Reverts when upstream vesting address is zero.
    error ZeroUpstream();
    /// @notice Reverts when badge root URI is empty.
    error BadgeUriEmpty();
    /// @notice Reverts when upstream vesting recipient is not this contract.
    error UpstreamRecipientMismatch();
    /// @notice Reverts when upstream vesting token does not match Zarosabe token.
    error UpstreamTokenMismatch();
    /// @notice Reverts on any SBT transfer attempt after mint.
    error SbtNonTransferable();
    /// @notice Reverts when SBT burn is attempted outside migration flow.
    error SbtBurnOnlyViaMigration();
    /// @notice Reverts on SBT approval operations.
    error SbtNonApprovable();
    /// @notice Reverts when trying to migrate a position to self.
    error SelfMigrationNotAllowed();
    /// @notice Reverts when sender has no active SBT to migrate.
    error SenderHasNoSbt();
    /// @notice Reverts when recipient already has active lock.
    error RecipientHasActiveLock();
    /// @notice Reverts when recipient has non-empty lock/reward/badge state.
    error RecipientNotClean();
    /// @notice Reverts when supporter emission is started more than once.
    error EmissionAlreadyStarted();
    /// @notice Reverts when emission start is attempted without at least one locked user.
    error AtLeastOneUserLock();
    /// @notice Reverts when upstream emission has not started.
    error UpstreamNotStarted();
    /// @notice Reverts when reward liquidity in pool is insufficient.
    error InsufficientVestingRewards();
    /// @notice Reverts when zero lock amount is provided.
    error ZeroAmount();
    /// @notice Reverts when operation is attempted after emission end where not allowed.
    error EmissionEnded();
    /// @notice Reverts when an address tries to mint SBT more than once.
    error SbtAlreadyMinted();
    /// @notice Reverts when operation requires started emission but it is not started.
    error EmissionNotStarted();
    /// @notice Reverts when claim/compound is attempted with zero reward.
    error NoReward();
    /// @notice Reverts when operation requires existing lock but user has none.
    error ZeroLockedNotAllowed();
    /// @notice Reverts when reward is below minimum compound threshold.
    error InsufficientClaimToCompound();
    /// @notice Reverts when unlock is attempted before global lock end.
    error LockNotEnded();
    /// @notice Reverts when unlock is attempted with zero principal.
    error NothingLocked();
    /// @notice Reverts when tokenURI query is made for non-existing SBT tokenId.
    error TokenIdNotExist();
    /// @notice Reverts when recipient address is zero.
    error ZeroRecipient();
    /// @notice Reverts when retrieve token address is zero.
    error ZeroToken();
    /// @notice Reverts when trying to retrieve vesting token.
    error RetrieveZarosabeNotAllowed();

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total rewards to be emitted over the duration (50B tokens with 18 decimals).
    uint256 public constant TOTAL_REWARD = 50_000_000_000e18;

    /// @notice Emission duration 5 years.
    uint256 public constant DURATION = (5 * 365 days);

    /// @notice Precision scalar for reward calculations.
    uint256 internal constant PRECISION = 1e18;

    /// @notice Basis points denominator (100%).
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ZAROSABE token interface.
    // solhint-disable-next-line immutable-vars-naming
    IZarosabeToken public immutable zarosabe;
    /// @notice Upstream linear vesting source.
    // solhint-disable-next-line immutable-vars-naming
    IVestingUpstream public immutable upstream;

    /*//////////////////////////////////////////////////////////////
                        EMISSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether emissions have started.
    bool public emissionStarted;

    /// @notice Timestamp when emissions began.
    uint256 public emissionStart;

    /// @notice Timestamp when emissions end (emissionStart + DURATION).
    uint256 public emissionEnd;

    /*//////////////////////////////////////////////////////////////
                        LOCKING STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total amount of tokens currently locked.
    uint256 public totalLocked;

    /// @notice Total number of unique supporters (wallets currently holding a unique SBT).
    uint256 public supporterCount;

    /// @notice Mapping of user address to their locked balance.
    mapping(address => uint256) public lockedBalance;

    /// @notice Peak locked amount per user (used for badge tier after unlock).
    mapping(address => uint256) public badgeLockedAmount;

    /*//////////////////////////////////////////////////////////////
                        REWARD ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Stored reward-per-token accumulator (global).
    uint256 public rewardPerTokenStored;

    /// @notice Last timestamp when rewards were updated.
    uint256 public lastUpdateTime;

    /// @notice Last reward-per-token value paid to each user.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending (unclaimed) rewards per user.
    mapping(address => uint256) public pendingRewards;

    /// @notice Total rewards that have been successfully distributed (claimed net + compounded gross, exclude burned).
    uint256 public totalRewardsDistributed;

    /*//////////////////////////////////////////////////////////////
                        SOULBOUND BADGE (SBT)
    //////////////////////////////////////////////////////////////*/

    /// @notice Counter for token IDs.
    uint256 private _tokenIdCounter;

    /// @notice Whether a user has already received their soulbound badge.
    mapping(address => bool) public hasSBT;

    /// @notice Active SBT token id by owner. Zero means no active SBT.
    mapping(address => uint256) private _sbtTokenIdByOwner;

    /// @dev Internal context flag to allow burn only while migration runs.
    bool private _burnContext;

    /// @notice Root IPFS for badge metadata
    string private _badgeRootURI;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when supporter emission schedule starts.
    /// @param startTime Emission start timestamp.
    /// @param endTime Emission end timestamp.
    event EmissionStarted(uint256 startTime, uint256 endTime);
    /// @notice Emitted when a user locks principal (or compounds into lock).
    /// @param user User address whose lock increased.
    /// @param amount Amount added to lock.
    event UserLock(address indexed user, uint256 amount);
    /// @notice Emitted when a user claims rewards with burn applied.
    /// @param user User claiming rewards.
    /// @param claimed Net amount transferred to user.
    /// @param burned Amount burned from gross reward.
    event Claimed(address indexed user, uint256 claimed, uint256 burned);
    /// @notice Emitted when a user compounds rewards (no burn path).
    /// @param user User compounding rewards.
    /// @param amount Reward amount compounded into principal.
    event Compound(address indexed user, uint256 amount);
    /// @notice Emitted when a user unlocks principal after emission end.
    /// @param user User unlocking.
    /// @param amount Principal amount returned.
    event Unlocked(address indexed user, uint256 amount);
    /// @notice Emitted when upstream vesting liquidity is pulled into this pool.
    /// @param amount Amount pulled from upstream in this call.
    event UpstreamPulled(uint256 amount);
    /// @notice Emitted when a user's peak-amount badge tier changes.
    /// @param user User address.
    /// @param previousTier Previous tier value.
    /// @param newTier New tier value.
    event BadgeTierUpdated(address indexed user, uint256 previousTier, uint256 newTier);
    /// @notice Emitted when a soulbound badge is minted for first-time locker.
    /// @param user Badge owner.
    /// @param tokenId Minted SBT tokenId.
    event BadgeMinted(address indexed user, uint256 tokenId);
    /// @notice Emitted when a soulbound badge is burned as part of migration.
    /// @param user Previous badge owner.
    /// @param tokenId Burned SBT tokenId.
    event BadgeBurned(address indexed user, uint256 tokenId);
    /// @notice Emitted when full position/accounting and SBT are migrated to a new wallet.
    /// @param from Old wallet.
    /// @param to New wallet.
    /// @param locked Amount of principal moved.
    /// @param pending Amount of pending reward moved.
    /// @param peak Peak locked amount history moved.
    /// @param oldTokenId Burned token id from old wallet.
    /// @param newTokenId Newly minted token id for new wallet.
    event PositionMigrated(
        address indexed from,
        address indexed to,
        uint256 locked,
        uint256 pending,
        uint256 peak,
        uint256 oldTokenId,
        uint256 newTokenId
    );
    /// @notice Emitted when non-ZAROSABE token retrieveal is attempted by owner.
    /// @param token Non-ZAROSABE token.
    /// @param amount Amount transferred.
    event TokenRetrieved(address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes supporter pool dependencies and badge metadata root.
     * @param _zarosabe The address of the ZAROSABE token contract.
     * @param _upstream The address of the upstream linear vesting contract.
     * @param badgeRootURI The badge root URI for badge metadata.
     * @dev Linkage to upstream recipient/token is validated in {startEmission}.
     * @dev Deployment does not start emissions; users can lock before start for fair launch.
     */
    constructor(
        address _zarosabe,
        address _upstream,
        string memory badgeRootURI
    ) Ownable(msg.sender) ERC721("Zarosabe Supporter", "ZSSBT") {
        if (_zarosabe == address(0)) revert ZeroZarosabe();
        if (_upstream == address(0)) revert ZeroUpstream();
        zarosabe = IZarosabeToken(_zarosabe);
        upstream = IVestingUpstream(_upstream);
        if (bytes(badgeRootURI).length == 0) revert BadgeUriEmpty();
        _badgeRootURI = badgeRootURI;
    }

    /*//////////////////////////////////////////////////////////////
                        SBT (BADGE) LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Blocks all transfers except minting and migration-scoped burn.
     * @param to Transfer target passed by ERC721 internals.
     * @param tokenId Token id being updated.
     * @param auth Authorized operator passed by ERC721 internals.
     * @return from Previous owner address returned by ERC721 internals.
     * @dev Any owner-to-owner transfer reverts to enforce soulbound behavior.
     * @dev Burn path (`to == address(0)`) is allowed only when `_burnContext` is true.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) revert SbtNonTransferable();
        if (from != address(0) && to == address(0) && !_burnContext) {
            revert SbtBurnOnlyViaMigration();
        }
    }

    /**
     * @dev Block approvals to prevent any possibility of future transfer.
     * @param `Unused.`
     * @param `Unused.`
     * @dev Always reverts with {SbtNonApprovable}.
     */
    function approve(address, uint256) public pure override {
        revert SbtNonApprovable();
    }

    /**
     * @dev Block approval-for-all to prevent any possibility of future transfer.
     * @param `Unused.`
     * @param `Unused.`
     * @dev Always reverts with {SbtNonApprovable}.
     */
    function setApprovalForAll(address, bool) public pure override {
        revert SbtNonApprovable();
    }

    /**
     * @dev Mints a new active soulbound badge for `user`.
     * @param user Badge owner.
     * @return tokenId Minted token id.
     * @dev Updates `hasSBT`, owner token-id index, and active supporter counter.
     */
    function _mintBadge(address user) internal returns (uint256 tokenId) {
        tokenId = ++_tokenIdCounter;
        _safeMint(user, tokenId);
        _sbtTokenIdByOwner[user] = tokenId;
        hasSBT[user] = true;
        ++supporterCount;
        emit BadgeMinted(user, tokenId);
    }

    /**
     * @dev Burns the active badge for `user` within migration context only.
     * @param user Current badge owner.
     * @return tokenId Burned token id.
     * @dev This function toggles `_burnContext` to satisfy {_update} burn guard.
     */
    function _burnBadgeDuringMigration(address user) internal returns (uint256 tokenId) {
        tokenId = _sbtTokenIdByOwner[user];
        _burnContext = true;
        _burn(tokenId);
        _burnContext = false;

        _sbtTokenIdByOwner[user] = 0;
        hasSBT[user] = false;
        --supporterCount;
        emit BadgeBurned(user, tokenId);
    }

    /**
     * @dev Returns whether recipient has empty position and accounting state.
     * @param user Address to validate.
     * @return True when recipient can safely receive a migrated position.
     */
    function _isCleanRecipient(address user) internal view returns (bool) {
        if (hasSBT[user]) return false;
        if (pendingRewards[user] != 0) return false;
        if (userRewardPerTokenPaid[user] != 0) return false;
        if (badgeLockedAmount[user] != 0) return false;
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        EMISSION INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Starts supporter emission period.
     * @dev Callable only once by owner and only when at least one user has locked.
     * @dev Emissions run exactly 5 years from current block timestamp.
     * @dev Strict upstream linkage is validated here:
     * - `upstream.emissionStarted()` must be true.
     * - `upstream.vestingRecipient()` must be this contract.
     * - `upstream.VESTING_TOKEN()` must match `zarosabe`.
     * @dev This call initializes reward accounting checkpoint (`lastUpdateTime`).
     */
    function startEmission() external onlyOwner {
        if (emissionStarted) revert EmissionAlreadyStarted();
        if (totalLocked == 0) revert AtLeastOneUserLock();
        if (!upstream.emissionStarted()) revert UpstreamNotStarted();
        if (upstream.vestingRecipient() != address(this)) revert UpstreamRecipientMismatch();
        if (address(upstream.VESTING_TOKEN()) != address(zarosabe)) revert UpstreamTokenMismatch();

        emissionStarted = true;
        emissionStart = block.timestamp;
        emissionEnd = emissionStart + DURATION;
        lastUpdateTime = emissionStart;

        emit EmissionStarted(emissionStart, emissionEnd);
    }

    /*//////////////////////////////////////////////////////////////
                    CALCULATION + ACCOUNTING HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns last timestamp eligible for reward accrual, capped at emission end.
     * @return The timestamp used for global reward accrual.
     * @dev Safe utility for accounting math; caller should enforce emission preconditions where needed.
     */
    function _lastTimeRewardApplicable() internal view returns (uint256) {
        return block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
    }

    /**
     * @notice Computes current global reward-per-token accumulator.
     * @dev Uses standard staking accrual formula; returns stored value when `totalLocked == 0`.
     * @return The updated reward-per-token value scaled by `PRECISION`.
     * @dev Formula increment:
     * `(timeDelta * TOTAL_REWARD * PRECISION) / (DURATION * totalLocked)`.
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalLocked == 0) return rewardPerTokenStored;

        uint256 timeDelta = _lastTimeRewardApplicable() - lastUpdateTime;
        return
            rewardPerTokenStored +
            (timeDelta * TOTAL_REWARD * PRECISION) /
            (DURATION * totalLocked);
    }

    /**
     * @notice Computes total earned rewards for a user.
     * @param user The address to query.
     * @return The total unclaimed rewards (checkpointed pending + fresh accrual).
     * @dev Read-only projection; does not mutate user checkpoints.
     */
    function earned(address user) public view returns (uint256) {
        return
            ((lockedBalance[user] * (rewardPerToken() - userRewardPerTokenPaid[user])) /
                PRECISION) + pendingRewards[user];
    }

    /**
     * @dev Updates global and optional user-specific reward accounting.
     * @param user The address of the user (`address(0)` skips user checkpoint update).
     * @dev Must be called before any state transition that changes lock balance or realizes rewards.
     */
    function _updateReward(address user) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = _lastTimeRewardApplicable();

        if (user != address(0)) {
            pendingRewards[user] = earned(user);
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        UPSTREAM VESTING PULL
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Pulls claimable rewards from upstream vesting and emits {UpstreamPulled} when positive.
     * @dev Uses pre/post token balance delta to compute actual received amount.
     * @dev Reverts if upstream emission has not started.
     */
    function _pullUpstream() internal {
        if (!upstream.emissionStarted()) revert UpstreamNotStarted();
        uint256 beforeBalance = zarosabe.balanceOf(address(this));
        upstream.claimVesting();
        uint256 afterBalance = zarosabe.balanceOf(address(this));

        uint256 pulled = afterBalance - beforeBalance;
        if (pulled > 0) emit UpstreamPulled(pulled);
    }

    /**
     * @dev Ensures enough liquid reward balance exists for immediate distribution needs.
     * @param required The amount of rewards needed for the calling path.
     * @dev Liquid rewards are computed as `balanceOf(this) - totalLocked`.
     * @dev May trigger upstream pull if upstream has remaining unclaimed amount.
     */
    function _ensureRewardBalance(uint256 required) internal {
        uint256 totalUpstreamClaimed = upstream.totalClaimed();
        if (totalUpstreamClaimed < TOTAL_REWARD) _pullUpstream();

        uint256 balance = zarosabe.balanceOf(address(this));
        if (balance <= totalLocked) revert InsufficientVestingRewards();
        uint256 available = balance - totalLocked;
        if (available < required) revert InsufficientVestingRewards();
    }

    /*//////////////////////////////////////////////////////////////
                            LOCKING + SBT MINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Locks tokens to participate in emissions and earns SBT.
     * @dev Updates rewards first, triggers lazy upstream pull, and mints SBT on first lock.
     * @dev Locking is disallowed after emission end.
     * @param amount The amount of tokens to lock.
     * @dev Lock balance influences both reward accrual and badge tier progression.
     */
    function lock(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Only prevent locking after emission has fully ended
        if (emissionStarted) {
            if (block.timestamp >= emissionEnd) revert EmissionEnded();
        }

        address user = msg.sender;
        _updateReward(user);

        bool isFirstLock = lockedBalance[user] == 0;
        uint256 prevTier = _badgeTierForAmount(badgeLockedAmount[user]);
        if (isFirstLock) {
            // Mint soulbound badge only when wallet has no active SBT
            if (hasSBT[user]) revert SbtAlreadyMinted();
            _mintBadge(user);
        }

        totalLocked += amount;
        lockedBalance[user] += amount;
        if (lockedBalance[user] > badgeLockedAmount[user]) {
            badgeLockedAmount[user] = lockedBalance[user];
        }
        uint256 newTier = _badgeTierForAmount(badgeLockedAmount[user]);
        if (!isFirstLock && newTier < prevTier) {
            emit BadgeTierUpdated(user, prevTier, newTier);
        }

        IERC20(address(zarosabe)).safeTransferFrom(user, address(this), amount);

        // Lazy pull to keep rewards topped up
        _pullUpstream();

        emit UserLock(user, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Applies time-based burn to rewards. Rounds burn amount UP.
     * @param reward The raw reward amount before burn.
     * @return claimable The amount the user can claim after burn.
     * @return burned The amount burned (rounded up).
     * @dev Burn schedule by elapsed year: 40% -> 30% -> 20% -> 10% -> 5% -> 0%.
     */
    function _applyBurn(uint256 reward) internal view returns (uint256 claimable, uint256 burned) {
        if (reward == 0) return (0, 0);

        uint256 elapsed = block.timestamp - emissionStart;

        uint256 burnBps; // Burn percentage in basis points (10000 = 100%)
        if (elapsed < 1 * 365 days)
            burnBps = 4000; // 40% burn
        else if (elapsed < 2 * 365 days)
            burnBps = 3000; // 30% burn
        else if (elapsed < 3 * 365 days)
            burnBps = 2000; // 20% burn
        else if (elapsed < 4 * 365 days)
            burnBps = 1000; // 10% burn
        else if (elapsed < 5 * 365 days)
            burnBps = 500; // 5% burn
        else burnBps = 0; // 0% burn

        // Round burn UP to favor burn side on dust amounts
        burned = (reward * burnBps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        claimable = reward - burned;
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIMING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims pending rewards with time-based burn applied.
     * @dev Call _claimInternal with non-reentrant.
     * @dev Net reward is transferred to caller; burned portion is destroyed.
     */
    function claim() external nonReentrant {
        _claimInternal(msg.sender);
    }

    /**
     * @dev Internal claim implementation for direct claim and unlock-triggered claim.
     * @param user The address of the user.
     * @dev Process:
     * 1) checkpoint user rewards,
     * 2) compute burn-adjusted payout,
     * 3) ensure liquidity,
     * 4) burn and transfer.
     */
    function _claimInternal(address user) internal {
        if (!emissionStarted) revert EmissionNotStarted();

        _updateReward(user);

        uint256 reward = pendingRewards[user];
        if (reward == 0) revert NoReward();

        pendingRewards[user] = 0;

        (uint256 claimable, uint256 burned) = _applyBurn(reward);

        _ensureRewardBalance(claimable + burned);

        if (burned > 0) {
            zarosabe.burn(burned);
        }

        if (claimable > 0) {
            IERC20(address(zarosabe)).safeTransfer(user, claimable);
            totalRewardsDistributed += claimable;
        }

        emit Claimed(user, claimable, burned);
    }

    /*//////////////////////////////////////////////////////////////
                        COMPOUND / CLAIM + LOCK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims pending rewards and immediately locks them back into the pool.
     * @dev	Combines claim + lock in one transaction for compounding (excludes burn as incentive).
     * @dev 1e10 is minimum reward amount expected to compound (slippage protection / dust prevention).
     * @dev Compounded rewards increase `totalLocked` and user lock without token transfer to user.
     */
    function compound() external nonReentrant {
        if (!emissionStarted) revert EmissionNotStarted();
        if (block.timestamp >= emissionEnd) revert EmissionEnded();

        address user = msg.sender;
        if (lockedBalance[user] == 0) revert ZeroLockedNotAllowed();
        _updateReward(user);

        uint256 reward = pendingRewards[user];
        uint256 prevTier = _badgeTierForAmount(badgeLockedAmount[user]);
        if (reward < 1e10) revert InsufficientClaimToCompound();

        pendingRewards[user] = 0;

        _ensureRewardBalance(reward);

        // Lock reward directly without burning
        totalLocked += reward;
        lockedBalance[user] += reward;
        if (lockedBalance[user] > badgeLockedAmount[user]) {
            badgeLockedAmount[user] = lockedBalance[user];
        }
        totalRewardsDistributed += reward;
        uint256 newTier = _badgeTierForAmount(badgeLockedAmount[user]);
        if (newTier < prevTier) {
            emit BadgeTierUpdated(user, prevTier, newTier);
        }

        emit Compound(user, reward);
        emit UserLock(user, reward);
    }

    /*//////////////////////////////////////////////////////////////
                            MIGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Migrates full position/accounting and SBT from caller to `newWallet`.
     * @dev Can be executed anytime, including after emission end.
     * @dev This operation does not claim, compound, or burn reward tokens.
     * @dev Migration does not change global economics
     *      (`totalLocked`, `rewardPerTokenStored`, `totalRewardsDistributed`).
     * @dev Sender must have active SBT and recipient must have clean state.
     * @param newWallet Destination wallet that receives the migrated state and SBT.
     */
    function migratePosition(address newWallet) external nonReentrant {
        if (newWallet == address(0)) revert ZeroRecipient();

        address from = msg.sender;
        if (newWallet == from) revert SelfMigrationNotAllowed();
        if (!hasSBT[from]) revert SenderHasNoSbt();
        if (lockedBalance[newWallet] != 0) revert RecipientHasActiveLock();
        if (!_isCleanRecipient(newWallet)) revert RecipientNotClean();

        // Checkpoint sender before moving any accounting fields.
        _updateReward(from);

        uint256 movedLocked = lockedBalance[from];
        uint256 movedPending = pendingRewards[from];
        uint256 movedPeak = badgeLockedAmount[from];
        uint256 movedPaid = userRewardPerTokenPaid[from];

        lockedBalance[newWallet] = movedLocked;
        pendingRewards[newWallet] = movedPending;
        userRewardPerTokenPaid[newWallet] = movedPaid;
        badgeLockedAmount[newWallet] = movedPeak;

        lockedBalance[from] = 0;
        pendingRewards[from] = 0;
        userRewardPerTokenPaid[from] = 0;
        badgeLockedAmount[from] = 0;

        uint256 oldTokenId = _burnBadgeDuringMigration(from);
        uint256 newTokenId = _mintBadge(newWallet);

        emit PositionMigrated(
            from,
            newWallet,
            movedLocked,
            movedPending,
            movedPeak,
            oldTokenId,
            newTokenId
        );
    }

    /*//////////////////////////////////////////////////////////////
								UNLOCK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Unlocks the principal after emissions end.
     * @dev Automatically claims any pending rewards first (0% burn post-end).
     * @dev Unlock is globally time-gated by `emissionEnd`.
     */
    function unlock() external nonReentrant {
        if (block.timestamp < emissionEnd) revert LockNotEnded();

        address user = msg.sender;
        uint256 principal = lockedBalance[user];
        if (principal == 0) revert NothingLocked();

        // Claim rewards while position still contributes (0% burn post-end)
        if (pendingRewards[user] > 0 || earned(user) > 0) {
            _claimInternal(user);
        }

        // Remove from accounting
        lockedBalance[user] = 0;
        totalLocked -= principal;

        IERC20(address(zarosabe)).safeTransfer(user, principal);

        emit Unlocked(user, principal);
    }

    /*//////////////////////////////////////////////////////////////
				SBT TOKEN URI (TIERED BY LOCKED AMOUNT)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the metadata URI for a given soulbound supporter badge.
     * @dev Tier is computed from the badge owner's peak locked balance.
     *      This preserves tier after unlock.
     *      The returned URI points to a static JSON file (metadata{tier}.json).
     *
     * @dev Reverts if the token does not exist (standard ERC721 behavior).
     *
     * @param tokenId The ID of the soulbound badge (NFT) to query.
     * @return The full IPFS URI to the metadata JSON (e.g., ipfs://Qm.../metadata1.json).
     * @dev Tier lookup uses peak-locked amount to preserve achievement after unlock.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenIdNotExist();
        address owner = ownerOf(tokenId);
        uint256 tier = _badgeTierForAmount(badgeLockedAmount[owner]);

        return string(abi.encodePacked(_badgeRootURI, "metadata", Strings.toString(tier), ".json"));
    }

    /**
     * @dev Returns badge tier based on locked amount thresholds.
     * @dev Assumes the ZAROSABE token uses 18 decimals.
     *      Tier 1: >= 1B
     *      Tier 2: >= 100M and < 1B
     *      Tier 3: >= 10M and < 100M
     *      Tier 4: >= 1M and < 10M
     *      Tier 5: < 1M
     * @return Badge tier based on locked amount thresholds.
     * @dev Lower numeric tier indicates higher threshold achievement.
     */
    function _badgeTierForAmount(uint256 amount) internal pure returns (uint256) {
        if (amount >= 1_000_000_000e18) return 1;
        if (amount >= 100_000_000e18) return 2;
        if (amount >= 10_000_000e18) return 3;
        if (amount >= 1_000_000e18) return 4;
        return 5;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current badge tier for a user based on peak locked balance.
     * @param user The address to query.
     * @return The tier number (1..5).
     * @dev Returns 0 when user has no minted SBT.
     */
    function badgeTier(address user) external view returns (uint256) {
        return hasSBT[user] ? _badgeTierForAmount(badgeLockedAmount[user]) : 0;
    }

    /**
     * @notice Returns the current badge tier for a given tokenId.
     * @param tokenId The SBT tokenId.
     * @return The tier number (1..5).
     * @dev Relies on ERC721 `ownerOf`; invalid tokenId reverts.
     */
    function badgeTierByTokenId(uint256 tokenId) external view returns (uint256) {
        address owner = ownerOf(tokenId);
        return _badgeTierForAmount(badgeLockedAmount[owner]);
    }

    /**
     * @notice Returns remaining tokens still claimable in the pool.
     * @return Remaining tokens still claimable in the pool.
     * @dev Excludes principal obligations (`totalLocked`) from pool balance.
     */
    function remainingClaimablePool() external view returns (uint256) {
        uint256 balance = zarosabe.balanceOf(address(this));
        if (balance <= totalLocked) return 0;
        return balance - totalLocked;
    }

    /**
     * @notice Returns the remaining tokens that still on upstream
     * @return Remaining emission from upstream
     * @dev Computed as `TOTAL_REWARD - upstream.totalClaimed()` with floor at zero.
     */
    function remainingUpstreamEmission() external view returns (uint256) {
        uint256 totalUpstreamClaimed = upstream.totalClaimed();
        if (TOTAL_REWARD <= totalUpstreamClaimed) return 0;
        return TOTAL_REWARD - totalUpstreamClaimed;
    }

    /**
     * @notice Returns the current emission rate per second per locked token (with precision).
     * @return Emission rate scaled by PRECISION (1e18). 0 if no lock or emissions ended.
     * @dev Snapshot helper; effective accrual remains time-weighted through reward checkpoints.
     */
    function currentEmissionRatePerSecond() external view returns (uint256) {
        if (totalLocked == 0 || !emissionStarted || block.timestamp >= emissionEnd) {
            return 0;
        }
        return (TOTAL_REWARD * PRECISION) / DURATION / totalLocked;
    }

    /**
     * @notice Returns current user position summary with real-time reward and burn estimates.
     * @dev All values are computed based on current block.timestamp.
     *      Useful for frontends to show "If I claim now" preview without simulating a transaction.
     * @param user The address to query.
     * @return locked The user's currently locked principal.
     * @return accrued Total raw / gross unclaimed rewards right now (pending + freshly accrued, before any burn).
     * @return burnedIfClaimNow Estimated burn amount if the user claims right now.
     * @return claimableIfClaimNow Estimated amount the user would actually receive if claiming now (after burn).
     * @return tier Current badge tier based on peak locked balance.
     * @dev Read-only projection and may differ from post-transaction state if concurrent activity occurs.
     */
    function getUserInfo(
        address user
    )
        external
        view
        returns (
            uint256 locked,
            uint256 accrued,
            uint256 burnedIfClaimNow,
            uint256 claimableIfClaimNow,
            uint256 tier
        )
    {
        locked = lockedBalance[user];

        // 1. Freshly accrued rewards since last _updateReward call
        uint256 freshAccrual = (locked * (rewardPerToken() - userRewardPerTokenPaid[user])) /
            PRECISION;

        // 2. Total raw rewards (pending + fresh accrual) — this is what you want as "accrued"
        accrued = pendingRewards[user] + freshAccrual;

        // 3. Apply current burn logic based on block.timestamp
        (uint256 estClaimable, uint256 estBurned) = _applyBurn(accrued);

        burnedIfClaimNow = estBurned;
        claimableIfClaimNow = estClaimable;
        tier = hasSBT[user] ? _badgeTierForAmount(badgeLockedAmount[user]) : 0;
    }

    /*//////////////////////////////////////////////////////////////
							OWNER HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieve token inside the contract (fees, airdrops, dust, stuck balance, etc ).
     * @dev Callable only by owner. Cannot retrieve ZAROSABE token and zero token is rejected.
     * @param token The token address to retrieve.
     * @dev Transfers full contract balance of `token` to owner.
     */
    function retrieveToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroToken();
        if (token == address(zarosabe)) revert RetrieveZarosabeNotAllowed();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenRetrieved(token, amount);
    }
}
