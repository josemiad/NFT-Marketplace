// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Script.sol";
import "../src/NFTMarketplace.sol";

contract DeployNFTMarketplace is Script {
    function run() external returns (NFTMarketplace marketplace) {
        vm.startBroadcast();
        marketplace = new NFTMarketplace();
        vm.stopBroadcast();
    }
}
