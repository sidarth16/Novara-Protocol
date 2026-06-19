// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/test/PoolModifyLiquidityTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

import {AbstractReactive} from "../../src/reactive/AbstractReactive.sol";
import {ILCalculator} from "../../src/libraries/ILCalculator.sol";
import {DeploymentRegistry} from "./DeploymentRegistry.sol";
import {NovaraAaveAdapter} from "../../src/NovaraAaveAdapter.sol";
import {NovaraDemoToken} from "../../src/demo/NovaraDemoToken.sol";
import {NovaraHook} from "../../src/NovaraHook.sol";
import {NovaraReactive} from "../../src/NovaraReactive.sol";
import {NovaraReserve} from "../../src/NovaraReserve.sol";
import {NovaraYieldVault} from "../../src/NovaraYieldVault.sol";
import {MockPriceFeed} from "../../src/demo/MockPriceFeed.sol";

abstract contract SepoliaDemoWorkflow is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for PoolManager;

    string internal constant DEFAULT_DEPLOYMENT_TAG = "v2";
    uint256 internal constant DEFAULT_PRIVATE_KEY = 0xA11CE;
    int24 internal constant LOWER_TICK = -60;
    int24 internal constant UPPER_TICK = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;
    uint256 internal constant DEMO_MINT_6 = 1_000_000_000 * 1e6;
    uint256 internal constant DEMO_MINT_18 = 1_000_000_000 * 1e18;
    uint256 internal constant POSITION_LIQUIDITY = 1_000_000;

    uint256 internal constant HOOK_POOL_POSITIONS_SLOT = 2;
    bytes32 internal constant PRICE_EXITED_TOPIC = keccak256("PriceExitedRange(bytes32,bytes32,int24)");
    bytes32 internal constant PRICE_ENTERED_TOPIC = keccak256("PriceEnteredRange(bytes32,bytes32,int24)");
    bytes32 internal constant CRON_TOPIC = keccak256("Cron100(uint256)");

    struct DemoContext {
        string deploymentTag;
        address broadcaster;
        DeploymentRegistry registry;
        NovaraHook hook;
        NovaraReserve reserve;
        NovaraYieldVault yieldVault;
        NovaraAaveAdapter adapter;
        NovaraReactive reactive;
        NovaraDemoToken usdc;
        NovaraDemoToken weth;
        PoolManager poolManager;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest modifyLiquidityRouter;
        PoolKey poolKey;
        PoolId poolId;
        bytes32 positionId;
        address positionOwner;
        MockPriceFeed priceFeed;
    }

    function _context() internal view returns (DemoContext memory ctx) {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        ctx.broadcaster = vm.addr(privateKey);
        ctx.deploymentTag = vm.envOr("NOVARA_DEPLOYMENT_TAG", DEFAULT_DEPLOYMENT_TAG);
        ctx.registry = _registry(ctx.broadcaster, ctx.deploymentTag);
        require(address(ctx.registry).code.length > 0, "deployment registry missing");
        require(ctx.registry.owner() == ctx.broadcaster, "registry owner mismatch");

        ctx.hook = NovaraHook(ctx.registry.hook());
        ctx.reserve = NovaraReserve(ctx.registry.reserve());
        ctx.yieldVault = NovaraYieldVault(ctx.registry.yieldVault());
        ctx.adapter = NovaraAaveAdapter(ctx.registry.adapter());
        ctx.reactive = NovaraReactive(ctx.registry.reactive());
        ctx.usdc = NovaraDemoToken(ctx.registry.usdc());
        ctx.weth = NovaraDemoToken(ctx.registry.weth());
        ctx.poolManager = PoolManager(ctx.registry.poolManager());
        ctx.swapRouter = PoolSwapTest(ctx.registry.swapRouter());
        ctx.modifyLiquidityRouter = PoolModifyLiquidityTest(ctx.registry.modifyLiquidityRouter());
        ctx.positionOwner = ctx.registry.modifyLiquidityRouter();
        (Currency c0, Currency c1) = _sortCurrencies(Currency.wrap(ctx.registry.usdc()), Currency.wrap(ctx.registry.weth()));
        ctx.poolKey = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(ctx.hook))});
        ctx.poolId = ctx.poolKey.toId();
        ctx.positionId = _positionId(ctx.positionOwner, ctx.poolId);
        ctx.priceFeed = MockPriceFeed(ctx.registry.priceFeed());
    }

    function _positionId(address positionOwner, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(positionOwner, poolId, LOWER_TICK, UPPER_TICK));
    }

    function _sortCurrencies(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) return (a, b);
        return (b, a);
    }

    function _registry(address broadcaster, string memory deploymentTag)
        internal
        pure
        returns (DeploymentRegistry)
    {
        bytes memory initCode = abi.encodePacked(type(DeploymentRegistry).creationCode, abi.encode(broadcaster));
        bytes32 salt = keccak256(abi.encodePacked("novara.deployment.registry.v1:", deploymentTag));
        address registryAddress = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        return DeploymentRegistry(payable(registryAddress));
    }

    function _poolPositionsLength(NovaraHook hook, PoolId poolId) internal view returns (uint256 length) {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(HOOK_POOL_POSITIONS_SLOT)));
        length = uint256(vm.load(address(hook), slot));
    }

    function _poolPositionAt(NovaraHook hook, PoolId poolId, uint256 index) internal view returns (bytes32 positionId) {
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(HOOK_POOL_POSITIONS_SLOT)));
        bytes32 dataSlot = bytes32(uint256(keccak256(abi.encode(base))) + index);
        positionId = vm.load(address(hook), dataSlot);
    }

    function _trackedPositionIds(DemoContext memory ctx) internal view returns (bytes32[] memory ids) {
        uint256 length = _poolPositionsLength(ctx.hook, ctx.poolId);
        ids = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            ids[i] = _poolPositionAt(ctx.hook, ctx.poolId, i);
        }
    }

    function _stateName(NovaraHook.PositionState state) internal pure returns (string memory) {
        if (state == NovaraHook.PositionState.ACTIVE) return "ACTIVE";
        if (state == NovaraHook.PositionState.IDLE) return "IDLE";
        return "EXITED";
    }

    function _printReserve(DemoContext memory ctx) internal view {
        (uint256 totalAssets, uint256 totalLiabilities, uint256 coverageRatioBps) = ctx.reserve.reserves(ctx.poolId);
        console2.log("Reserve assets", totalAssets);
        console2.log("Reserve liabilities", totalLiabilities);
        console2.log("Reserve coverage", coverageRatioBps);
    }

    function _printPosition(DemoContext memory ctx, bytes32 positionId) internal view {
        NovaraHook.Position memory position = ctx.hook.getPosition(positionId);
        NovaraHook.ProtectionProfile memory profile = ctx.hook.getProtectionProfile(positionId);
        // console2.log("Position", positionId);
        console2.log("Owner", position.owner);
        // console2.log("PoolId", PoolId.unwrap(position.poolId));
        console2.log("Ticks", position.tickLower);
        console2.log("Ticks upper", position.tickUpper);
        console2.log("Liquidity", uint256(position.liquidity));
        console2.log("Entry price", uint256(position.entryPrice));
        console2.log("Last tick", position.lastTick);
        console2.log("Entry timestamp", position.entryTimestamp);
        console2.log("State", _stateName(position.state));
        console2.log("Auto redeploy", profile.autoRedeploy);
        console2.log("Auto exit", profile.autoExit);
        console2.log("Exit coverage threshold", profile.exitCoverageThreshold);
    }

    function _printAaveAndVault(DemoContext memory ctx, bytes32 positionId) internal view {
        (address token, address aToken, uint256 originalAmount, uint256 aTokenAmount, uint256 depositTimestamp) =
            ctx.hook.aaveDeposits(positionId);
        console2.log("Hook Aave token", token);
        console2.log("Hook Aave aToken", aToken);
        console2.log("Hook Aave principal", originalAmount);
        console2.log("Hook Aave aTokenAmount", aTokenAmount);
        console2.log("Hook Aave timestamp", depositTimestamp);

        if (token != address(0)) {
            (uint256 principal, uint256 vaultDepositTimestamp) = ctx.yieldVault.deposits(token, address(ctx.adapter));
            (uint256 apyBps, uint256 totalPrincipal, uint256 accruedYield, uint256 lastAccrualTimestamp, bool configured) =
                ctx.yieldVault.assetStates(token);
            console2.log("Vault principal", principal);
            console2.log("Vault deposit timestamp", vaultDepositTimestamp);
            console2.log("Vault APY", apyBps);
            console2.log("Vault total principal", totalPrincipal);
            console2.log("Vault accrued yield", accruedYield);
            console2.log("Vault last accrual", lastAccrualTimestamp);
            console2.log("Vault configured", configured);
        }
    }

    function _currentTick(DemoContext memory ctx) internal view returns (int24 tick) {
        (, tick,,) = ctx.poolManager.getSlot0(ctx.poolId);
    }

    function _activePositionCount(DemoContext memory ctx) internal view returns (uint256 count) {
        bytes32[] memory ids = _trackedPositionIds(ctx);
        for (uint256 i = 0; i < ids.length; i++) {
            NovaraHook.Position memory position = ctx.hook.getPosition(ids[i]);
            if (position.state != NovaraHook.PositionState.EXITED) count++;
        }
    }

    function _mintAndApprove(DemoContext memory ctx) internal {
        ctx.usdc.mint(ctx.broadcaster, DEMO_MINT_6);
        ctx.weth.mint(ctx.broadcaster, DEMO_MINT_18);
        ctx.usdc.mint(address(ctx.adapter), DEMO_MINT_6);
        ctx.weth.mint(address(ctx.adapter), DEMO_MINT_18);
        ctx.usdc.approve(address(ctx.swapRouter), type(uint256).max);
        ctx.weth.approve(address(ctx.swapRouter), type(uint256).max);
        ctx.usdc.approve(address(ctx.modifyLiquidityRouter), type(uint256).max);
        ctx.weth.approve(address(ctx.modifyLiquidityRouter), type(uint256).max);
    }

    function _reproduceOutOfRange(DemoContext memory ctx) internal {
        ctx.swapRouter.swap(
            ctx.poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1e24),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(int24(-120))
        );
        ctx.priceFeed.setPrice(125_000_000);
        ctx.reactive.react(
            AbstractReactive.LogRecord({
                topic0: PRICE_EXITED_TOPIC,
                data: abi.encode(ctx.positionId, ctx.poolId, int24(-120))
            })
        );
    }

    function _reenterRange(DemoContext memory ctx) internal returns (bool upkeepNeeded, bytes memory performData) {
        ctx.priceFeed.setPrice(100_000_000);
        return ctx.hook.checkUpkeep(abi.encode(ctx.poolId));
    }

    function _accrueYield(DemoContext memory ctx) internal returns (uint256 accrued) {
        (address token,, uint256 principal,,) = ctx.hook.aaveDeposits(ctx.positionId);
        accrued = ctx.yieldVault.accrueYield(token);
        ctx.reactive.react(
            AbstractReactive.LogRecord({topic0: CRON_TOPIC, data: abi.encode(block.timestamp)})
        );
        console2.log("Accrual token", token);
        console2.log("Accrual principal", principal);
        console2.log("Accrued amount", accrued);
    }

    function _performUpkeep(DemoContext memory ctx, bytes memory performData) internal {
        ctx.hook.performUpkeep(performData);
    }

    function _exitLiquidity(DemoContext memory ctx) internal returns (uint256 ilAmount) {
        NovaraHook.Position memory position = ctx.hook.getPosition(ctx.positionId);
        uint160 exitPrice = TickMath.getSqrtPriceAtTick(0);
        ilAmount = ILCalculator.computeIL(
            position.entryPrice,
            exitPrice,
            position.tickLower,
            position.tickUpper,
            position.liquidity
        );
        ctx.modifyLiquidityRouter.modifyLiquidity(
            ctx.poolKey,
            ModifyLiquidityParams({
                tickLower: LOWER_TICK,
                tickUpper: UPPER_TICK,
                liquidityDelta: -int128(uint128(POSITION_LIQUIDITY)),
                salt: bytes32(0)
            }),
            abi.encode(int24(0))
        );
    }

    function _positionExists(DemoContext memory ctx) internal view returns (bool) {
        return _poolPositionsLength(ctx.hook, ctx.poolId) > 0;
    }
}
