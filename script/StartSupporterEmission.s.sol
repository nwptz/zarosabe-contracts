// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {ZarosabeSupporter} from "../contracts/ZarosabeSupporter.sol";

/// @notice Starts emission for an already deployed ZarosabeSupporter contract.
/// @dev Uses env vars:
/// - PRIVATE_KEY
/// - SUPPORTER_ADDRESS
/// @dev This call will revert unless at least one user has locked before execution.
contract StartSupporterEmissionScript is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address supporterAddress = vm.envAddress("SUPPORTER_ADDRESS");

        vm.startBroadcast(privateKey);
        ZarosabeSupporter(supporterAddress).startEmission();
        vm.stopBroadcast();
    }
}
