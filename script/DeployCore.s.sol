// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {DeploymentRegistry} from "./utils/DeploymentRegistry.sol";
import {MockPriceFeed} from "../src/demo/MockPriceFeed.sol";
import {NovaraAaveAdapter} from "../src/NovaraAaveAdapter.sol";
import {NovaraDemoToken} from "../src/demo/NovaraDemoToken.sol";
import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraReactive} from "../src/NovaraReactive.sol";
import {NovaraReserve} from "../src/NovaraReserve.sol";
import {NovaraYieldVault} from "../src/NovaraYieldVault.sol";

contract DeployCore is Script {
    uint160 internal constant HOOK_FLAGS =
        Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;
    string internal constant DEFAULT_DEPLOYMENT_TAG = "v1";
    uint256 internal constant DEFAULT_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant INITIAL_PRICE = 100_000_000;

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address broadcaster = vm.addr(privateKey);
        string memory deploymentTag = vm.envOr("NOVARA_DEPLOYMENT_TAG", DEFAULT_DEPLOYMENT_TAG);
        address registryAddress = _registryAddress(broadcaster, deploymentTag);
        DeploymentRegistry registry = DeploymentRegistry(payable(registryAddress));

        if (address(registry).code.length > 0 && registry.usdc() != address(0)) {
            revert("core already deployed");
        }

        vm.startBroadcast(privateKey);

        if (address(registry).code.length == 0) {
            registry = new DeploymentRegistry{salt: _registrySalt(deploymentTag)}(broadcaster);
        }

        NovaraDemoToken usdc = new NovaraDemoToken("NovaraUSDC", "nUSDC", 6);
        NovaraDemoToken weth = new NovaraDemoToken("NovaraWETH", "nWETH", 18);
        bytes memory hookCreationCode = type(NovaraHook).creationCode;
        (address predictedHook, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, hookCreationCode, "");
        predictedHook;
        address hookAddress = address(new NovaraHook{salt: salt}());
        NovaraReserve reserve = new NovaraReserve(hookAddress);
        NovaraYieldVault yieldVault = new NovaraYieldVault();
        NovaraAaveAdapter adapter = new NovaraAaveAdapter(address(yieldVault), hookAddress);
        NovaraReactive reactive = new NovaraReactive(hookAddress);
        MockPriceFeed priceFeed = new MockPriceFeed(int256(INITIAL_PRICE));

        registry.registerCore(
            address(usdc),
            address(weth),
            hookAddress,
            address(reserve),
            address(yieldVault),
            address(adapter),
            address(reactive),
            address(priceFeed)
        );

        vm.stopBroadcast();

        console2.log("=== Novara Core ===");
        console2.log("Deployment tag", deploymentTag);
        console2.log("Registry", registryAddress);
        console2.log("Broadcaster", broadcaster);
        console2.log("NovaraUSDC", address(usdc));
        console2.log("NovaraWETH", address(weth));
        console2.log("NovaraHook", hookAddress);
        console2.log("NovaraReserve", address(reserve));
        console2.log("NovaraYieldVault", address(yieldVault));
        console2.log("NovaraAaveAdapter", address(adapter));
        console2.log("NovaraReactive", address(reactive));
        console2.log("MockPriceFeed", address(priceFeed));
    }

    function _registryAddress(address broadcaster, string memory deploymentTag) internal pure returns (address) {
        bytes memory initCode = abi.encodePacked(type(DeploymentRegistry).creationCode, abi.encode(broadcaster));
        return vm.computeCreate2Address(_registrySalt(deploymentTag), keccak256(initCode), CREATE2_FACTORY);
    }

    function _registrySalt(string memory deploymentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("novara.deployment.registry.v1:", deploymentTag));
    }
}
