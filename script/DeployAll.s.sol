// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgioVault} from "../src/AgioVault.sol";
import {AgioBatchSettlement} from "../src/AgioBatchSettlement.sol";
import {AgioRegistry} from "../src/AgioRegistry.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC:", address(usdc));

        // 2. Deploy AgioVault (proxy)
        AgioVault vaultImpl = new AgioVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(vaultImpl.initialize, (address(usdc), 100_000e6))
        );
        AgioVault vault = AgioVault(address(vaultProxy));
        console.log("AgioVault:", address(vault));

        // 3. Deploy AgioRegistry (proxy)
        AgioRegistry regImpl = new AgioRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(regImpl.initialize, ())
        );
        AgioRegistry registry = AgioRegistry(address(regProxy));
        console.log("AgioRegistry:", address(registry));

        // 4. Deploy AgioBatchSettlement (proxy)
        AgioBatchSettlement batchImpl = new AgioBatchSettlement();
        ERC1967Proxy batchProxy = new ERC1967Proxy(
            address(batchImpl),
            abi.encodeCall(batchImpl.initialize, (address(vault), address(registry), 500))
        );
        AgioBatchSettlement batch = AgioBatchSettlement(address(batchProxy));
        console.log("AgioBatchSettlement:", address(batch));

        // 5. Grant roles
        vault.grantRole(vault.SETTLEMENT_ROLE(), address(batch));
        registry.grantRole(registry.BATCH_SETTLEMENT_ROLE(), address(batch));

        // 6. Set batch signer to deployer (change to API signer in production)
        batch.setBatchSigner(deployer);

        vm.stopBroadcast();

        console.log("--- Deployment Complete ---");
        console.log("USDC:", address(usdc));
        console.log("Vault:", address(vault));
        console.log("Registry:", address(registry));
        console.log("BatchSettlement:", address(batch));
    }
}
