// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PoolManager} from "@uniswap/v4-core/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";

import {DeploymentRegistry} from "./utils/DeploymentRegistry.sol";
import {NovaraHook} from "../src/NovaraHook.sol";

contract DeployPool is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for PoolManager;

    string internal constant DEFAULT_DEPLOYMENT_TAG = "v1";
    uint256 internal constant DEFAULT_PRIVATE_KEY = 0xA11CE;
    int24 internal constant LOWER_TICK = -60;
    int24 internal constant UPPER_TICK = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address broadcaster = vm.addr(privateKey);
        string memory deploymentTag = vm.envOr("NOVARA_DEPLOYMENT_TAG", DEFAULT_DEPLOYMENT_TAG);
        DeploymentRegistry registry = _registryFor(broadcaster, deploymentTag);

        require(address(registry).code.length > 0, "deployment registry missing");
        require(registry.owner() == broadcaster, "registry owner mismatch");
        require(registry.hook() != address(0), "hook missing");
        require(registry.usdc() != address(0), "usdc missing");
        require(registry.weth() != address(0), "weth missing");
        require(registry.poolManager() == address(0), "pool already deployed");

        NovaraHook hook = NovaraHook(registry.hook());
        (Currency c0, Currency c1) = _sortCurrencies(Currency.wrap(registry.usdc()), Currency.wrap(registry.weth()));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});

        Hooks.Permissions memory permissions = hook.getHookPermissions();
        require(permissions.afterAddLiquidity, "hook missing afterAddLiquidity");
        require(permissions.beforeRemoveLiquidity, "hook missing beforeRemoveLiquidity");
        require(permissions.beforeSwap, "hook missing beforeSwap");
        require(address(hook.reserve()) == registry.reserve(), "reserve not wired");
        require(address(hook.aaveAdapter()) == registry.adapter(), "adapter not wired");
        require(hook.reactiveContract() == registry.reactive(), "reactive not wired");
        require(hook.chainlinkForwarder() == broadcaster, "forwarder not wired");
        require(address(hook.priceFeed()) == registry.priceFeed(), "price feed not wired");

        console2.log("=== Deploy Pool ===");
        console2.log("Deployment tag", deploymentTag);
        console2.log("Caller", broadcaster);
        console2.log("Pool token0", Currency.unwrap(c0));
        console2.log("Pool token1", Currency.unwrap(c1));
        console2.log("Fee", FEE);
        console2.log("Tick spacing", TICK_SPACING);
        console2.log("Hook", address(hook));

        vm.startBroadcast(privateKey);

        PoolManager poolManager = new PoolManager(broadcaster);
        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        poolManager.initialize(key, INITIAL_SQRT_PRICE);
        registry.registerPool(address(poolManager), address(swapRouter), address(modifyLiquidityRouter));

        vm.stopBroadcast();

        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        console2.log("PoolManager", address(poolManager));
        console2.log("SwapRouter", address(swapRouter));
        console2.log("ModifyLiquidityRouter", address(modifyLiquidityRouter));
        console2.log("Initialized tick", tick);
    }

    function _sortCurrencies(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
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
