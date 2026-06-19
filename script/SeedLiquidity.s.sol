// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PoolManager} from "@uniswap/v4-core/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";

import {DeploymentRegistry} from "./utils/DeploymentRegistry.sol";
import {NovaraDemoToken} from "../src/demo/NovaraDemoToken.sol";
import {NovaraHook} from "../src/NovaraHook.sol";

contract SeedLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for PoolManager;

    string internal constant DEFAULT_DEPLOYMENT_TAG = "v1";
    uint256 internal constant DEFAULT_PRIVATE_KEY = 0xA11CE;
    int24 internal constant LOWER_TICK = -60;
    int24 internal constant UPPER_TICK = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant DEMO_MINT_6 = 1_000_000_000 * 1e6;
    uint256 internal constant DEMO_MINT_18 = 1_000_000_000 * 1e18;
    uint160 internal constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address broadcaster = vm.addr(privateKey);
        string memory deploymentTag = vm.envOr("NOVARA_DEPLOYMENT_TAG", DEFAULT_DEPLOYMENT_TAG);
        DeploymentRegistry registry = _registryFor(broadcaster, deploymentTag);

        require(address(registry).code.length > 0, "deployment registry missing");
        require(registry.owner() == broadcaster, "registry owner mismatch");
        require(registry.poolManager() != address(0), "pool manager missing");
        require(registry.swapRouter() != address(0), "swap router missing");
        require(registry.modifyLiquidityRouter() != address(0), "modify router missing");
        require(registry.hook() != address(0), "hook missing");

        NovaraDemoToken usdc = NovaraDemoToken(registry.usdc());
        NovaraDemoToken weth = NovaraDemoToken(registry.weth());
        PoolManager poolManager = PoolManager(registry.poolManager());
        PoolSwapTest swapRouter = PoolSwapTest(registry.swapRouter());
        PoolModifyLiquidityTest modifyLiquidityRouter = PoolModifyLiquidityTest(registry.modifyLiquidityRouter());
        NovaraHook hook = NovaraHook(registry.hook());

        (Currency c0, Currency c1) = _sortCurrencies(Currency.wrap(registry.usdc()), Currency.wrap(registry.weth()));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});
        PoolId poolId = key.toId();

        require(poolManager.getLiquidity(poolId) == 0, "liquidity already seeded");

        console2.log("=== Seed Liquidity ===");
        console2.log("Deployment tag", deploymentTag);
        console2.log("Caller", broadcaster);
        console2.log("USDC before", usdc.balanceOf(broadcaster));
        console2.log("WETH before", weth.balanceOf(broadcaster));
        console2.log("USDC allowance swap", usdc.allowance(broadcaster, address(swapRouter)));
        console2.log("WETH allowance swap", weth.allowance(broadcaster, address(swapRouter)));
        console2.log("USDC allowance lp", usdc.allowance(broadcaster, address(modifyLiquidityRouter)));
        console2.log("WETH allowance lp", weth.allowance(broadcaster, address(modifyLiquidityRouter)));

        vm.startBroadcast(privateKey);

        usdc.mint(broadcaster, DEMO_MINT_6);
        weth.mint(broadcaster, DEMO_MINT_18);
        usdc.mint(registry.adapter(), DEMO_MINT_6);
        weth.mint(registry.adapter(), DEMO_MINT_18);

        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);

        require(usdc.allowance(broadcaster, address(swapRouter)) > 0, "usdc swap approval missing");
        require(weth.allowance(broadcaster, address(swapRouter)) > 0, "weth swap approval missing");
        require(usdc.allowance(broadcaster, address(modifyLiquidityRouter)) > 0, "usdc lp approval missing");
        require(weth.allowance(broadcaster, address(modifyLiquidityRouter)) > 0, "weth lp approval missing");

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LOWER_TICK,
                tickUpper: UPPER_TICK,
                liquidityDelta: int128(uint128(1_000_000)),
                salt: bytes32(0)
            }),
            abi.encode(
                int24(0),
                NovaraHook.ProtectionProfile({autoRedeploy: true, autoExit: false, exitCoverageThreshold: 2500})
            )
        );

        vm.stopBroadcast();

        console2.log("USDC after", usdc.balanceOf(broadcaster));
        console2.log("WETH after", weth.balanceOf(broadcaster));
        console2.log("Pool liquidity", poolManager.getLiquidity(poolId));
        console2.log("USDC adapter", usdc.balanceOf(registry.adapter()));
        console2.log("WETH adapter", weth.balanceOf(registry.adapter()));
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
