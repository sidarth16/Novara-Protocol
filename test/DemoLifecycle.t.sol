// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/test/PoolSwapTest.sol";

import {Deployers} from "../lib/v4-core/test/utils/Deployers.sol";
import {HookMinerLocal} from "./HookMinerLocal.sol";

import {AbstractReactive} from "../src/reactive/AbstractReactive.sol";
import {IAggregatorV3Like} from "../src/interfaces/IAggregatorV3Like.sol";
import {NovaraAaveAdapter} from "../src/NovaraAaveAdapter.sol";
import {NovaraDemoToken} from "../src/demo/NovaraDemoToken.sol";
import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraReactive} from "../src/NovaraReactive.sol";
import {NovaraReserve} from "../src/NovaraReserve.sol";
import {NovaraYieldVault} from "../src/NovaraYieldVault.sol";

contract MockPriceFeedDemo is IAggregatorV3Like {
    int256 internal price = 100_000_000;

    function setPrice(int256 price_) external {
        price = price_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        answer = price;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }
}

contract DemoLifecycleTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    NovaraDemoToken internal usdc;
    NovaraDemoToken internal weth;
    NovaraYieldVault internal yieldVault;
    NovaraHook internal hook;
    NovaraReserve internal reserve;
    NovaraAaveAdapter internal adapter;
    NovaraReactive internal reactive;
    MockPriceFeedDemo internal priceFeed;
    PoolKey internal demoKey;

    address internal positionOwner = address(this);
    int24 internal constant LOWER_TICK = -60;
    int24 internal constant UPPER_TICK = 60;
    uint128 internal constant LIQUIDITY = 1_000_000;
    uint256 internal constant POSITION_AMOUNT = 1_000_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        positionOwner = address(modifyLiquidityRouter);

        usdc = new NovaraDemoToken("NovaraUSDC", "nUSDC", 6);
        weth = new NovaraDemoToken("NovaraWETH", "nWETH", 18);

        (Currency c0, Currency c1) = _sortCurrencies(Currency.wrap(address(usdc)), Currency.wrap(address(weth)));
        demoKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        bytes memory creationCode = type(NovaraHook).creationCode;
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
        (address calculatedHook, bytes32 salt) = HookMinerLocal.find(address(this), flags, creationCode, bytes(""));
        hook = new NovaraHook{salt: salt}();
        assertEq(address(hook), calculatedHook);

        demoKey.hooks = IHooks(address(hook));

        reserve = new NovaraReserve(address(hook));
        yieldVault = new NovaraYieldVault();
        adapter = new NovaraAaveAdapter(address(yieldVault), address(hook));
        reactive = new NovaraReactive(address(hook));
        priceFeed = new MockPriceFeedDemo();

        hook.setReserve(address(reserve));
        hook.setAaveAdapter(address(adapter));
        hook.setReactiveContract(address(reactive));
        hook.setChainlinkForwarder(address(this));
        hook.setPriceFeed(address(priceFeed));

        yieldVault.setAssetConfig(address(usdc), 450);
        yieldVault.setAssetConfig(address(weth), 380);
        priceFeed.setPrice(100_000_000);

        _fundDemoBalances();

        manager.initialize(demoKey, TickMath.getSqrtPriceAtTick(0));
        _addDemoLiquidity();
    }

    function _sortCurrencies(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) {
            return (a, b);
        }
        return (b, a);
    }

    function _fundDemoBalances() internal {
        uint256 lpBalance6 = 1_000_000_000e6;
        uint256 lpBalance18 = 1_000_000e18;
        usdc.mint(address(this), lpBalance6);
        weth.mint(address(this), lpBalance18);
        usdc.mint(address(adapter), lpBalance6);
        weth.mint(address(adapter), lpBalance18);

        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function _profile() internal pure returns (NovaraHook.ProtectionProfile memory) {
        return NovaraHook.ProtectionProfile({autoRedeploy: true, autoExit: false, exitCoverageThreshold: 2500});
    }

    function _hookData(int24 currentTick) internal pure returns (bytes memory) {
        return abi.encode(currentTick, _profile());
    }

    function _swapHookData(int24 currentTick) internal pure returns (bytes memory) {
        return abi.encode(currentTick);
    }

    function _positionId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(positionOwner, demoKey.toId(), LOWER_TICK, UPPER_TICK));
    }

    function _addDemoLiquidity() internal {
        modifyLiquidityRouter.modifyLiquidity(
            demoKey,
            ModifyLiquidityParams({
                tickLower: LOWER_TICK,
                tickUpper: UPPER_TICK,
                liquidityDelta: int128(uint128(LIQUIDITY)),
                salt: bytes32(0)
            }),
            _hookData(0)
        );
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(demoKey.toId());
    }

    function movePriceOutOfRange() internal {
        swapRouter.swap(
            demoKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1e24),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _swapHookData(-120)
        );
        priceFeed.setPrice(125_000_000);

        reactive.react(
            AbstractReactive.LogRecord({
                topic0: reactive.PRICE_EXITED_TOPIC(),
                data: abi.encode(_positionId(), demoKey.toId(), int24(-120))
            })
        );
    }

    function accrueYield() internal {
        vm.warp(block.timestamp + 14 days);
        yieldVault.accrueYield(Currency.unwrap(demoKey.currency0));
        reactive.react(
            AbstractReactive.LogRecord({topic0: reactive.CRON_TOPIC(), data: abi.encode(block.timestamp)})
        );
    }

    function movePriceIntoRange() internal {
        priceFeed.setPrice(100_000_000);

        (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep(abi.encode(demoKey.toId()));
        assertTrue(upkeepNeeded);
        hook.performUpkeep(performData);
    }

    function test_DemoLifecycle_ActiveIdleVaultYieldRecallExit() public {
        bytes32 positionId = _positionId();

        NovaraHook.Position memory initialPosition = hook.getPosition(positionId);
        assertEq(uint8(initialPosition.state), uint8(NovaraHook.PositionState.ACTIVE));

        movePriceOutOfRange();

        NovaraHook.Position memory idlePosition = hook.getPosition(positionId);
        assertEq(uint8(idlePosition.state), uint8(NovaraHook.PositionState.IDLE));

        (, , uint256 originalAmount, uint256 aTokenAmount,) = hook.aaveDeposits(positionId);
        assertEq(originalAmount, POSITION_AMOUNT);
        assertEq(aTokenAmount, POSITION_AMOUNT);

        uint256 reserveAssetsBeforeYield;
        (reserveAssetsBeforeYield,,) = reserve.reserves(demoKey.toId());

        accrueYield();

        movePriceIntoRange();

        NovaraHook.Position memory activeAgain = hook.getPosition(positionId);
        assertEq(uint8(activeAgain.state), uint8(NovaraHook.PositionState.ACTIVE));

        (, , uint256 afterRecallPrincipal, ,) = hook.aaveDeposits(positionId);
        assertEq(afterRecallPrincipal, 0);

        (uint256 reserveAssetsAfterRecall,, uint256 coverageAfterRecall) = reserve.reserves(demoKey.toId());
        assertGt(reserveAssetsAfterRecall, reserveAssetsBeforeYield);
        assertGt(coverageAfterRecall, 0);

        modifyLiquidityRouter.modifyLiquidity(
            demoKey,
            ModifyLiquidityParams({
                tickLower: LOWER_TICK,
                tickUpper: UPPER_TICK,
                liquidityDelta: -int128(uint128(LIQUIDITY)),
                salt: bytes32(0)
            }),
            _swapHookData(0)
        );

        NovaraHook.Position memory exited = hook.getPosition(positionId);
        assertEq(uint8(exited.state), uint8(NovaraHook.PositionState.EXITED));
        (uint256 finalAssets,, uint256 finalCoverage) = reserve.reserves(demoKey.toId());
        assertEq(finalAssets, reserveAssetsAfterRecall);
        assertGt(finalCoverage, 0);
    }
}
