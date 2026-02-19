// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenSample} from "../contracts/TokenSample.sol";
import {LinearVesting} from "../contracts/LinearVesting.sol";

contract LinearVestingTest is Test {
    TokenSample internal token;
    LinearVesting internal vesting;

    address internal marketRecipient = address(0xBEEF);
    address internal recipient = address(0xCAFE);
    address internal newRecipient = address(0xD00D);
    address internal otherUser = address(0x1234);

    function setUp() external {
        token = new TokenSample(marketRecipient);
        vesting = new LinearVesting(address(token), address(0));
        token.initializeVesting(address(vesting));
    }

    function test_Constructor_DefaultRecipientToOwnerWhenZeroOverride() external view {
        assertEq(vesting.vestingRecipient(), address(this));
        assertEq(address(vesting.VESTING_TOKEN()), address(token));
    }

    function test_Constructor_UsesRecipientOverrideWhenProvided() external {
        LinearVesting v = new LinearVesting(address(token), recipient);
        assertEq(v.vestingRecipient(), recipient);
    }

    function test_Constructor_RevertOnZeroToken() external {
        vm.expectRevert(LinearVesting.InvalidToken.selector);
        new LinearVesting(address(0), recipient);
    }

    function test_SetVestingRecipient_OnlyOwner() external {
        vm.prank(otherUser);
        vm.expectRevert();
        vesting.setVestingRecipient(newRecipient);
    }

    function test_SetVestingRecipient_RevertOnZeroRecipient() external {
        vm.expectRevert(LinearVesting.InvalidRecipient.selector);
        vesting.setVestingRecipient(address(0));
    }

    function test_SetVestingRecipient_UpdatesRecipient() external {
        vesting.setVestingRecipient(newRecipient);
        assertEq(vesting.vestingRecipient(), newRecipient);
    }

    function test_StartEmission_RevertWhenUnderfunded() external {
        LinearVesting v = new LinearVesting(address(token), address(0));
        vm.expectRevert(LinearVesting.InsufficientFunding.selector);
        v.startEmission();
    }

    function test_StartEmission_RevertWhenCalledTwice() external {
        vesting.startEmission();
        vm.expectRevert(LinearVesting.EmissionAlreadyStarted.selector);
        vesting.startEmission();
    }

    function test_StartEmission_SetsSchedule() external {
        uint256 beforeTs = block.timestamp;
        vesting.startEmission();

        assertTrue(vesting.emissionStarted());
        assertEq(vesting.vestingStartTime(), beforeTs);
        assertEq(vesting.vestingEndTime(), beforeTs + vesting.VESTING_DURATION());
    }

    function test_ClaimVesting_RevertBeforeStart() external {
        vm.expectRevert(LinearVesting.EmissionNotStarted.selector);
        vesting.claimVesting();
    }

    function test_ClaimableAmount_Boundaries() external {
        vesting.startEmission();
        uint256 start = vesting.vestingStartTime();
        uint256 end = vesting.vestingEndTime();

        vm.warp(start);
        assertEq(vesting.getClaimableAmount(), 0);

        vm.warp(end);
        assertEq(vesting.getClaimableAmount(), vesting.VESTING_SUPPLY());
    }

    function test_ClaimVesting_TransfersToRecipientAndUpdatesTotalClaimed() external {
        vesting.setVestingRecipient(recipient);
        vesting.startEmission();

        uint256 mid = vesting.vestingStartTime() + vesting.VESTING_DURATION() / 2;
        vm.warp(mid);

        uint256 expected = vesting.getClaimableAmount();
        uint256 beforeBal = token.balanceOf(recipient);

        uint256 claimed = vesting.claimVesting();

        assertEq(claimed, expected);
        assertEq(token.balanceOf(recipient), beforeBal + expected);
        assertEq(vesting.totalClaimed(), expected);
    }

    function test_ClaimVesting_ReturnsZeroWhenNothingClaimable() external {
        vesting.startEmission();
        uint256 start = vesting.vestingStartTime();
        vm.warp(start);
        assertEq(vesting.claimVesting(), 0);
    }

    function test_RemainingVesting_DecreasesAfterClaim() external {
        vesting.startEmission();
        vm.warp(vesting.vestingStartTime() + 30 days);

        uint256 beforeRemaining = token.balanceOf(address(vesting));
        vesting.claimVesting();
        uint256 afterRemaining = token.balanceOf(address(vesting));

        assertLt(afterRemaining, beforeRemaining);
    }
}
