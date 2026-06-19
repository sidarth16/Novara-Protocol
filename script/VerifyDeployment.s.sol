// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PoolManager} from "@uniswap/v4-core/PoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";

import {DeploymentRegistry} from "./utils/DeploymentRegistry.sol";
import {NovaraAaveAdapter} from "../src/NovaraAaveAdapter.sol";
import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraReserve} from "../src/NovaraReserve.sol";
import {NovaraYieldVault} from "../src/NovaraYieldVault.sol";

contract VerifyDeployment is Script {
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

    function run() external view {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address broadcaster = vm.addr(privateKey);
        string memory deploymentTag = vm.envOr("NOVARA_DEPLOYMENT_TAG", DEFAULT_DEPLOYMENT_TAG);
        DeploymentRegistry registry = _registryFor(broadcaster, deploymentTag);

        require(address(registry).code.length > 0, "deployment registry missing");
        require(registry.owner() == broadcaster, "registry owner mismatch");
        require(registry.usdc() != address(0), "usdc missing");
        require(registry.weth() != address(0), "weth missing");
        require(registry.hook() != address(0), "hook missing");
        require(registry.reserve() != address(0), "reserve missing");
        require(registry.yieldVault() != address(0), "yield vault missing");
        require(registry.adapter() != address(0), "adapter missing");
        require(registry.reactive() != address(0), "reactive missing");
        require(registry.priceFeed() != address(0), "price feed missing");
        require(registry.poolManager() != address(0), "pool manager missing");
        require(registry.swapRouter() != address(0), "swap router missing");
        require(registry.modifyLiquidityRouter() != address(0), "modify router missing");
        require(registry.chainlinkForwarder() == broadcaster, "forwarder mismatch");

        NovaraHook hook = NovaraHook(registry.hook());
        NovaraReserve reserve = NovaraReserve(registry.reserve());
        NovaraYieldVault yieldVault = NovaraYieldVault(registry.yieldVault());
        NovaraAaveAdapter adapter = NovaraAaveAdapter(registry.adapter());
        PoolManager poolManager = PoolManager(registry.poolManager());

        (Currency c0, Currency c1) = _sortCurrencies(Currency.wrap(registry.usdc()), Currency.wrap(registry.weth()));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});
        PoolId poolId = key.toId();

        console2.log("=== Verify Deployment ===");
        console2.log("Deployment tag", deploymentTag);
        console2.log("Registry", address(registry));
        console2.log("Broadcaster", broadcaster);
        console2.logBytes32(PoolId.unwrap(poolId));

        require(address(hook.reserve()) == registry.reserve(), "hook reserve mismatch");
        require(address(hook.aaveAdapter()) == registry.adapter(), "hook adapter mismatch");
        require(hook.reactiveContract() == registry.reactive(), "hook reactive mismatch");
        require(hook.chainlinkForwarder() == broadcaster, "hook forwarder mismatch");
        require(address(hook.priceFeed()) == registry.priceFeed(), "hook price feed mismatch");

        require(reserve.hook() == registry.hook(), "reserve hook mismatch");
        require(adapter.hook() == registry.hook(), "adapter hook mismatch");
        require(address(adapter.aavePool()) == address(yieldVault), "adapter pool mismatch");
        require(yieldVault.owner() == broadcaster, "yield vault owner mismatch");
        require(yieldVault.currentAPY(registry.usdc()) == 450, "usdc APY mismatch");
        require(yieldVault.currentAPY(registry.weth()) == 380, "weth APY mismatch");

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        require(sqrtPriceX96 == INITIAL_SQRT_PRICE, "pool price mismatch");
        require(tick == 0, "pool tick mismatch");
        require(poolManager.getLiquidity(poolId) > 0, "pool has no liquidity");

        (address token0, address token1) = hook.poolConfigs(poolId);
        require(token0 == Currency.unwrap(c0), "pool token0 mismatch");
        require(token1 == Currency.unwrap(c1), "pool token1 mismatch");
        require(hook.hasPrimaryPool(), "primary pool not set");
        require(PoolId.unwrap(hook.primaryPoolId()) == PoolId.unwrap(poolId), "primary pool id mismatch");

        console2.log("Hook reserve", address(hook.reserve()));
        console2.log("Hook adapter", address(hook.aaveAdapter()));
        console2.log("Hook reactive", hook.reactiveContract());
        console2.log("Hook forwarder", hook.chainlinkForwarder());
        console2.log("Pool liquidity", poolManager.getLiquidity(poolId));
        console2.log("USDC APY", yieldVault.currentAPY(registry.usdc()));
        console2.log("WETH APY", yieldVault.currentAPY(registry.weth()));
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
