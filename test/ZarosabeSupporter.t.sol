// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenSample} from "../contracts/TokenSample.sol";
import {LinearVesting} from "../contracts/LinearVesting.sol";
import {ZarosabeSupporter} from "../contracts/ZarosabeSupporter.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ZarosabeSupporterBurnHarness is ZarosabeSupporter {
    constructor(
        address _zarosabe,
        address _upstream,
        string memory badgeRootURI
    ) ZarosabeSupporter(_zarosabe, _upstream, badgeRootURI) {}

    function forceBurn(uint256 tokenId) external {
        _burn(tokenId);
    }
}

contract ZarosabeSupporterTest is Test {
    TokenSample internal token;
    LinearVesting internal vesting;
    ZarosabeSupporter internal supporter;
    MockERC20 internal mock;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC0FFEE);

    uint256 internal constant INITIAL_LOCK = 1_000_000e18;
    string internal constant BADGE_ROOT_URI = "ipfs://zarosabe-badges/";

    function setUp() external {
        token = new TokenSample(address(this));
        vesting = new LinearVesting(address(token), address(0));
        supporter = new ZarosabeSupporter(address(token), address(vesting), BADGE_ROOT_URI);
        mock = new MockERC20();

        token.initializeVesting(address(vesting));
    }

    function _startUpstreamAndLockForAlice() internal {
        vesting.setVestingRecipient(address(supporter));
        vesting.startEmission();
        vesting.renounceOwnership();

        assertTrue(token.transfer(alice, INITIAL_LOCK));
        vm.startPrank(alice);
        token.approve(address(supporter), INITIAL_LOCK);
        supporter.lock(INITIAL_LOCK);
        vm.stopPrank();
    }

    function _activateSupporterWithAliceLock() internal {
        _startUpstreamAndLockForAlice();
        supporter.startEmission();
    }

    function _fundAndLock(address user, uint256 amount) internal {
        assertTrue(token.transfer(user, amount));
        vm.startPrank(user);
        token.approve(address(supporter), amount);
        supporter.lock(amount);
        vm.stopPrank();
    }

    function test_StartEmission_RevertWithoutAnyLock() external {
        vm.expectRevert(ZarosabeSupporter.AtLeastOneUserLock.selector);
        supporter.startEmission();
    }

    function test_StartEmission_RevertWhenUpstreamRecipientMismatch() external {
        vesting.setVestingRecipient(alice);
        vesting.startEmission();

        assertTrue(token.transfer(alice, INITIAL_LOCK));
        vm.startPrank(alice);
        token.approve(address(supporter), INITIAL_LOCK);
        supporter.lock(INITIAL_LOCK);
        vm.stopPrank();

        vm.expectRevert(ZarosabeSupporter.UpstreamRecipientMismatch.selector);
        supporter.startEmission();
    }

    function test_Lock_MintsSbtOnceAndIncrementsSupporterCount() external {
        _startUpstreamAndLockForAlice();

        assertEq(supporter.supporterCount(), 1);
        assertTrue(supporter.hasSBT(alice));
        assertEq(supporter.ownerOf(1), alice);
    }

    function test_Lock_RevertWhenSbtTransferAttempted() external {
        _startUpstreamAndLockForAlice();

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.SbtNonTransferable.selector);
        supporter.transferFrom(alice, bob, 1);
    }

    function test_MigratePosition_MovesFullState_AndBurnsMintsSbt() external {
        _activateSupporterWithAliceLock();

        vm.warp(block.timestamp + 30 days);
        uint256 pendingAlice = supporter.earned(alice);
        uint256 peakAlice = supporter.badgeLockedAmount(alice);
        uint256 lockedAlice = supporter.lockedBalance(alice);
        uint256 totalLockedBefore = supporter.totalLocked();
        uint256 totalRewardsDistributedBefore = supporter.totalRewardsDistributed();
        uint256 countBefore = supporter.supporterCount();

        vm.prank(alice);
        supporter.migratePosition(bob);

        assertEq(supporter.supporterCount(), countBefore);
        assertFalse(supporter.hasSBT(alice));
        assertTrue(supporter.hasSBT(bob));
        assertEq(supporter.lockedBalance(alice), 0);
        assertEq(supporter.lockedBalance(bob), lockedAlice);
        assertEq(supporter.pendingRewards(alice), 0);
        assertEq(supporter.pendingRewards(bob), pendingAlice);
        assertEq(supporter.badgeLockedAmount(alice), 0);
        assertEq(supporter.badgeLockedAmount(bob), peakAlice);
        assertEq(supporter.totalLocked(), totalLockedBefore);
        assertEq(supporter.totalRewardsDistributed(), totalRewardsDistributedBefore);

        vm.expectRevert();
        supporter.ownerOf(1);
        assertEq(supporter.ownerOf(2), bob);
    }

    function test_MigratePosition_WorksAfterEmissionEnd_WithLockedPosition() external {
        _activateSupporterWithAliceLock();

        vm.warp(supporter.emissionEnd() + 1);

        vm.prank(alice);
        supporter.migratePosition(bob);

        assertEq(supporter.lockedBalance(alice), 0);
        assertEq(supporter.lockedBalance(bob), INITIAL_LOCK);
        assertTrue(supporter.hasSBT(bob));
    }

    function test_MigratePosition_WorksAfterUnlock_ForBadgeHistoryOnly() external {
        _activateSupporterWithAliceLock();

        vm.warp(supporter.emissionEnd());
        vm.prank(alice);
        supporter.unlock();

        uint256 peakBefore = supporter.badgeLockedAmount(alice);
        assertGt(peakBefore, 0);

        vm.prank(alice);
        supporter.migratePosition(bob);

        assertEq(supporter.lockedBalance(bob), 0);
        assertEq(supporter.badgeLockedAmount(alice), 0);
        assertEq(supporter.badgeLockedAmount(bob), peakBefore);
        assertFalse(supporter.hasSBT(alice));
        assertTrue(supporter.hasSBT(bob));
    }

    function test_MigratePosition_WorksAfterEmissionEnd_AfterClaim_NotUnlocked() external {
        _activateSupporterWithAliceLock();

        vm.warp(supporter.emissionEnd() + 1);

        vm.prank(alice);
        supporter.claim();

        uint256 lockedBefore = supporter.lockedBalance(alice);
        uint256 peakBefore = supporter.badgeLockedAmount(alice);
        assertGt(lockedBefore, 0);
        assertGt(peakBefore, 0);

        vm.prank(alice);
        supporter.migratePosition(bob);

        assertEq(supporter.lockedBalance(alice), 0);
        assertEq(supporter.lockedBalance(bob), lockedBefore);
        assertEq(supporter.badgeLockedAmount(alice), 0);
        assertEq(supporter.badgeLockedAmount(bob), peakBefore);
        assertFalse(supporter.hasSBT(alice));
        assertTrue(supporter.hasSBT(bob));
    }

    function test_MigratePosition_WorksAfterEmissionEnd_AfterClaimAndUnlock() external {
        _activateSupporterWithAliceLock();

        vm.warp(supporter.emissionEnd() + 1);

        vm.prank(alice);
        supporter.claim();

        vm.prank(alice);
        supporter.unlock();

        uint256 peakBefore = supporter.badgeLockedAmount(alice);
        assertEq(supporter.lockedBalance(alice), 0);
        assertGt(peakBefore, 0);
        assertTrue(supporter.hasSBT(alice));

        vm.prank(alice);
        supporter.migratePosition(bob);

        assertEq(supporter.lockedBalance(bob), 0);
        assertEq(supporter.badgeLockedAmount(alice), 0);
        assertEq(supporter.badgeLockedAmount(bob), peakBefore);
        assertFalse(supporter.hasSBT(alice));
        assertTrue(supporter.hasSBT(bob));
    }

    function test_MigratePosition_RevertWhenRecipientHasActiveLock() external {
        _activateSupporterWithAliceLock();
        _fundAndLock(bob, 100e18);

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.RecipientHasActiveLock.selector);
        supporter.migratePosition(bob);
    }

    function test_MigratePosition_RevertWhenRecipientHasActiveSbtWithoutLock() external {
        _activateSupporterWithAliceLock();
        _fundAndLock(charlie, 100e18);

        vm.warp(supporter.emissionEnd());
        vm.prank(charlie);
        supporter.unlock();

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.RecipientNotClean.selector);
        supporter.migratePosition(charlie);
    }

    function test_MigratePosition_RevertOnInvalidRecipient() external {
        _startUpstreamAndLockForAlice();

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.ZeroRecipient.selector);
        supporter.migratePosition(address(0));

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.SelfMigrationNotAllowed.selector);
        supporter.migratePosition(alice);
    }

    function test_MigratePosition_RevertWhenSenderHasNoSbt() external {
        _startUpstreamAndLockForAlice();

        vm.prank(bob);
        vm.expectRevert(ZarosabeSupporter.SenderHasNoSbt.selector);
        supporter.migratePosition(charlie);
    }

    function test_SbtBurn_RevertOutsideMigrationContext() external {
        ZarosabeSupporterBurnHarness harness = new ZarosabeSupporterBurnHarness(
            address(token),
            address(vesting),
            BADGE_ROOT_URI
        );

        vesting.setVestingRecipient(address(harness));
        vesting.startEmission();
        vesting.renounceOwnership();

        address dave = address(0xD00D);
        uint256 amount = 100e18;
        assertTrue(token.transfer(dave, amount));
        vm.startPrank(dave);
        token.approve(address(harness), amount);
        harness.lock(amount);
        vm.stopPrank();

        vm.expectRevert(ZarosabeSupporter.SbtBurnOnlyViaMigration.selector);
        harness.forceBurn(1);
    }

    function test_Claim_RevertBeforeSupporterEmissionStart() external {
        _startUpstreamAndLockForAlice();

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.EmissionNotStarted.selector);
        supporter.claim();
    }

    function test_Claim_WorksAfterSupporterEmissionStart() external {
        _activateSupporterWithAliceLock();

        vm.warp(block.timestamp + 30 days);
        uint256 beforeBal = token.balanceOf(alice);

        vm.prank(alice);
        supporter.claim();

        uint256 afterBal = token.balanceOf(alice);
        assertGt(afterBal, beforeBal);
    }

    function test_Compound_RevertWhenRewardTooSmall() external {
        _activateSupporterWithAliceLock();

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.InsufficientClaimToCompound.selector);
        supporter.compound();
    }

    function test_Unlock_RevertBeforeEmissionEnd() external {
        _activateSupporterWithAliceLock();

        vm.prank(alice);
        vm.expectRevert(ZarosabeSupporter.LockNotEnded.selector);
        supporter.unlock();
    }

    function test_Unlock_WorksAfterEmissionEnd() external {
        _activateSupporterWithAliceLock();

        uint256 locked = supporter.lockedBalance(alice);
        uint256 beforeBal = token.balanceOf(alice);

        vm.warp(supporter.emissionEnd());
        vm.prank(alice);
        supporter.unlock();

        uint256 afterBal = token.balanceOf(alice);
        assertEq(supporter.lockedBalance(alice), 0);
        assertGe(afterBal, beforeBal + locked);
    }

    function test_RetrieveToken_OnlyOwner_AndRejectZarosabe() external {
        vm.prank(alice);
        vm.expectRevert();
        supporter.retrieveToken(address(mock));

        vm.expectRevert(ZarosabeSupporter.RetrieveZarosabeNotAllowed.selector);
        supporter.retrieveToken(address(token));
    }

    function test_RetrieveToken_TransfersNonZarosabeTokenToOwner() external {
        uint256 amount = 123e18;
        mock.mint(address(supporter), amount);
        uint256 beforeOwnerBal = mock.balanceOf(address(this));

        supporter.retrieveToken(address(mock));

        assertEq(mock.balanceOf(address(supporter)), 0);
        assertEq(mock.balanceOf(address(this)), beforeOwnerBal + amount);
    }
}
