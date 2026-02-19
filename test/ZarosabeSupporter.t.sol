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

contract ZarosabeSupporterTest is Test {
    TokenSample internal token;
    LinearVesting internal vesting;
    ZarosabeSupporter internal supporter;
    MockERC20 internal mock;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

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

        token.transfer(alice, INITIAL_LOCK);
        vm.startPrank(alice);
        token.approve(address(supporter), INITIAL_LOCK);
        supporter.lock(INITIAL_LOCK);
        vm.stopPrank();
    }

    function _activateSupporterWithAliceLock() internal {
        _startUpstreamAndLockForAlice();
        supporter.startEmission();
    }

    function test_StartEmission_RevertWithoutAnyLock() external {
        vm.expectRevert(ZarosabeSupporter.AtLeastOneUserLock.selector);
        supporter.startEmission();
    }

    function test_StartEmission_RevertWhenUpstreamRecipientMismatch() external {
        vesting.setVestingRecipient(alice);
        vesting.startEmission();

        token.transfer(alice, INITIAL_LOCK);
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
