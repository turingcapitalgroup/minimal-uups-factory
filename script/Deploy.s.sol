// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { Script, console } from "forge-std/Script.sol";
import { MinimalUUPSFactory } from "../src/MinimalUUPSFactory.sol";

contract DeployScript is Script {
    function run() external returns (MinimalUUPSFactory factory) {
        vm.startBroadcast();

        factory = new MinimalUUPSFactory();
        console.log("MinimalUUPSFactory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
