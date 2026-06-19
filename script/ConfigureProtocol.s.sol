// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentRegistry} from "./utils/DeploymentRegistry.sol";
import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraYieldVault} from "../src/NovaraYieldVault.sol";

contract ConfigureProtocol is Script {
    string internal constant DEFAULT_DEPLOYMENT_TAG = "v1";
    uint256 internal constant DEFAULT_PRIVATE_KEY = 0xA11CE;

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address broadcaster = vm.addr(privateKey);
        string memory deploymentTag = vm.envOr("NOVARA_DEPLOYMENT_TAG", DEFAULT_DEPLOYMENT_TAG);
        DeploymentRegistry registry = _registryFor(broadcaster, deploymentTag);

        require(address(registry).code.length > 0, "deployment registry missing");
        require(registry.owner() == broadcaster, "registry owner mismatch");
        require(registry.usdc() != address(0), "core not deployed");
        require(registry.hook() != address(0), "hook missing");
        require(registry.reserve() != address(0), "reserve missing");
        require(registry.yieldVault() != address(0), "yield vault missing");
        require(registry.adapter() != address(0), "adapter missing");
        require(registry.reactive() != address(0), "reactive missing");
        require(registry.priceFeed() != address(0), "price feed missing");

        NovaraHook hook = NovaraHook(registry.hook());
        NovaraYieldVault yieldVault = NovaraYieldVault(registry.yieldVault());

        console2.log("=== Configure Protocol ===");
        console2.log("Deployment tag", deploymentTag);
        console2.log("Caller", broadcaster);
        console2.log("Registry owner", registry.owner());
        console2.log("Hook deployer", hook.deployer());

        vm.startBroadcast(privateKey);

        require(address(hook.reserve()) == address(0), "reserve already configured");
        require(address(hook.aaveAdapter()) == address(0), "adapter already configured");
        require(hook.reactiveContract() == address(0), "reactive already configured");
        require(hook.chainlinkForwarder() == address(0), "forwarder already configured");
        require(address(hook.priceFeed()) == address(0), "price feed already configured");
        require(yieldVault.owner() == broadcaster, "yield vault owner mismatch");

        hook.setReserve(registry.reserve());
        hook.setAaveAdapter(registry.adapter());
        hook.setReactiveContract(registry.reactive());
        hook.setChainlinkForwarder(broadcaster);
        hook.setPriceFeed(registry.priceFeed());
        yieldVault.setAssetConfig(registry.usdc(), 450);
        yieldVault.setAssetConfig(registry.weth(), 380);

        registry.registerProtocol(broadcaster);

        vm.stopBroadcast();

        console2.log("Hook reserve", address(hook.reserve()));
        console2.log("Hook adapter", address(hook.aaveAdapter()));
        console2.log("Hook reactive", hook.reactiveContract());
        console2.log("Hook forwarder", hook.chainlinkForwarder());
        console2.log("Hook price feed", address(hook.priceFeed()));
        console2.log("USDC APY", yieldVault.currentAPY(registry.usdc()));
        console2.log("WETH APY", yieldVault.currentAPY(registry.weth()));
    }

    function _registryFor(address broadcaster, string memory deploymentTag) internal pure returns (DeploymentRegistry) {
        bytes memory initCode = abi.encodePacked(type(DeploymentRegistry).creationCode, abi.encode(broadcaster));
        address registryAddress = vm.computeCreate2Address(_registrySalt(deploymentTag), keccak256(initCode), CREATE2_FACTORY);
        return DeploymentRegistry(payable(registryAddress));
    }

    function _registrySalt(string memory deploymentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("novara.deployment.registry.v1:", deploymentTag));
    }
}
