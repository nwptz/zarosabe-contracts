// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TokenSample} from "../contracts/TokenSample.sol";
import {LinearVesting} from "../contracts/LinearVesting.sol";
import {ZarosabeSupporter} from "../contracts/ZarosabeSupporter.sol";

/// @notice Deploys and configures Zarosabe contracts up to upstream ownership renounce.
/// @dev Uses env vars:
/// - PRIVATE_KEY
/// - MARKET_RECIPIENT
/// - BADGE_ROOT_URI
contract DeployAndSetupScript is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address marketRecipient = vm.envAddress("MARKET_RECIPIENT");
        string memory badgeRootUri = vm.envString("BADGE_ROOT_URI");

        vm.startBroadcast(privateKey);

        TokenSample token = new TokenSample(marketRecipient);
        LinearVesting linearVesting = new LinearVesting(address(token), address(0));
        ZarosabeSupporter supporter = new ZarosabeSupporter(
            address(token),
            address(linearVesting),
            badgeRootUri
        );

        token.initializeVesting(address(linearVesting));
        linearVesting.setVestingRecipient(address(supporter));
        linearVesting.startEmission();
        linearVesting.renounceOwnership();

        vm.stopBroadcast();

        console2.log("TokenSample:", address(token));
        console2.log("LinearVesting:", address(linearVesting));
        console2.log("ZarosabeSupporter:", address(supporter));
    }
}
