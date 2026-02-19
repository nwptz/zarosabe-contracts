// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenSample} from "../contracts/TokenSample.sol";

contract TokenSampleTest is Test {
    TokenSample internal token;

    address internal marketRecipient = address(0xBEEF);
    address internal vestingRecipient = address(0xCAFE);
    address internal user = address(0x1234);

    function setUp() external {
        token = new TokenSample(marketRecipient);
    }

    function test_Constructor_DistributesSupplyCorrectly() external view {
        assertEq(token.balanceOf(marketRecipient), token.COIN_MARKET_SUPPLY());
        assertEq(token.balanceOf(address(token)), token.VESTING_SUPPLY());
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function test_Constructor_RevertOnZeroMarketRecipient() external {
        vm.expectRevert(TokenSample.ZeroAddress.selector);
        new TokenSample(address(0));
    }

    function test_InitializeVesting_TransfersFullVestingSupply() external {
        token.initializeVesting(vestingRecipient);

        assertTrue(token.vestingInitialized());
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(vestingRecipient), token.VESTING_SUPPLY());
    }

    function test_InitializeVesting_RevertOnZeroRecipient() external {
        vm.expectRevert(TokenSample.ZeroAddress.selector);
        token.initializeVesting(address(0));
    }

    function test_InitializeVesting_RevertWhenCalledTwice() external {
        token.initializeVesting(vestingRecipient);

        vm.expectRevert(TokenSample.VestingAlreadyInitialized.selector);
        token.initializeVesting(vestingRecipient);
    }

    function test_InitializeVesting_OnlyOwner() external {
        vm.prank(user);
        vm.expectRevert();
        token.initializeVesting(vestingRecipient);
    }

    function test_Burn_ReducesBalanceAndTotalSupply() external {
        uint256 burnAmount = 1_000e18;

        vm.prank(marketRecipient);
        token.burn(burnAmount);

        assertEq(token.balanceOf(marketRecipient), token.COIN_MARKET_SUPPLY() - burnAmount);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY() - burnAmount);
    }

    function test_Burn_RevertWhenInsufficientBalance() external {
        vm.prank(user);
        vm.expectRevert();
        token.burn(1e18);
    }
}
