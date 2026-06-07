// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

import {IAggregatorV3Like} from "../src/interfaces/IAggregatorV3Like.sol";
import {IAavePoolLike} from "../src/interfaces/IAavePoolLike.sol";
import {NovaraAaveAdapter} from "../src/NovaraAaveAdapter.sol";
import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraReactive} from "../src/NovaraReactive.sol";
import {NovaraReserve} from "../src/NovaraReserve.sol";
import {AbstractReactive} from "../src/reactive/AbstractReactive.sol";

contract MockAavePoolLikeFL is IAavePoolLike {
    mapping(address => ReserveData) internal reserves;
    mapping(address => mapping(address => uint256)) internal balances;

    function setReserve(address asset, uint256 availableLiquidity, uint128 currentLiquidityRate, address aTokenAddress)
        external
    {
        reserves[asset] = ReserveData({
            availableLiquidity: availableLiquidity,
            currentLiquidityRate: currentLiquidityRate,
            aTokenAddress: aTokenAddress
        });
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        ReserveData storage reserve = reserves[asset];
        require(amount <= reserve.availableLiquidity, "insufficient liquidity");
        reserve.availableLiquidity -= amount;
        balances[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn) {
        to;
        ReserveData storage reserve = reserves[asset];
        uint256 balance = balances[msg.sender][asset];
        withdrawn = amount > balance ? balance : amount;
        balances[msg.sender][asset] = balance - withdrawn;
        reserve.availableLiquidity += withdrawn;
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        return reserves[asset];
    }
}

contract MockPriceFeedFL is IAggregatorV3Like {
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

contract FullLifecycleTest is Test {
    using PoolIdLibrary for PoolKey;

    MockAavePoolLikeFL internal pool;
    MockPriceFeedFL internal priceFeed;
    NovaraHook internal hook;
    NovaraReserve internal reserve;
    NovaraAaveAdapter internal adapter;
    NovaraReactive internal reactive;
    PoolKey internal key;
    address internal owner = address(0xA11CE);
    address internal token0 = address(0x1111);
    address internal token1 = address(0x2222);

    function setUp() public {
        pool = new MockAavePoolLikeFL();
        priceFeed = new MockPriceFeedFL();
        hook = new NovaraHook();
        reserve = new NovaraReserve(address(hook));
        adapter = new NovaraAaveAdapter(address(pool), address(hook));
        reactive = new NovaraReactive(address(hook));

        hook.setReserve(address(reserve));
        hook.setAaveAdapter(address(adapter));
        hook.setReactiveContract(address(reactive));
        hook.setChainlinkForwarder(address(this));
        hook.setPriceFeed(address(priceFeed));

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        pool.setReserve(token0, 1_000_000 ether, 40_000_000_000_000_000_000_000_000, address(0xA7001));
        pool.setReserve(token1, 1_000_000 ether, 45_000_000_000_000_000_000_000_000, address(0xA7002));
    }

    function _profile(bool autoRedeploy, bool autoExit, uint256 exitCoverageThreshold)
        internal
        pure
        returns (NovaraHook.ProtectionProfile memory)
    {
        return NovaraHook.ProtectionProfile({
            autoRedeploy: autoRedeploy,
            autoExit: autoExit,
            exitCoverageThreshold: exitCoverageThreshold
        });
    }

    function _addHookData(int24 currentTick, NovaraHook.ProtectionProfile memory profile)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(currentTick, profile);
    }

    function _swapHookData(int24 currentTick) internal pure returns (bytes memory) {
        return abi.encode(currentTick);
    }

    function _positionId(address account, int24 tickLower, int24 tickUpper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(account, key.toId(), tickLower, tickUpper));
    }

    function test_CheckUpkeep_ReturnsFalse_WhenNoneIdle() public view {
        (bool upkeepNeeded, ) = hook.checkUpkeep(abi.encode(key.toId()));
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_ReturnsFalse_WhenIdleButOutOfRange() public {
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: 180, tickUpper: 240, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );

        (bool upkeepNeeded, ) = hook.checkUpkeep(abi.encode(key.toId()));
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_ReturnsTrue_WhenIdleAndInRange() public {
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );
        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );

        (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep(abi.encode(key.toId()));
        assertTrue(upkeepNeeded);
        (PoolId poolId, bytes32[] memory toRedeploy, uint256 count, int24 currentTick) =
            abi.decode(performData, (PoolId, bytes32[], uint256, int24));
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()));
        assertEq(count, 1);
        assertEq(toRedeploy[0], _positionId(owner, -60, 60));
        assertEq(currentTick, 0);
    }

    function test_PerformUpkeep_RedeploysFromAave() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        bytes32 positionId = _positionId(owner, tickLower, tickUpper);

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );
        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );
        hook.deployToAave(positionId);

        (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep(abi.encode(key.toId()));
        assertTrue(upkeepNeeded);
        hook.performUpkeep(performData);

        NovaraHook.Position memory position = hook.getPosition(positionId);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.ACTIVE));
        (, , uint256 originalAmount, ,) = hook.aaveDeposits(positionId);
        assertEq(originalAmount, 0);
    }

    function test_ReactiveCallback_AccessControl() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        bytes32 positionId = _positionId(owner, tickLower, tickUpper);

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );
        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );

        vm.prank(address(0xBEEF));
        vm.expectRevert(NovaraHook.UnauthorizedCaller.selector);
        hook.deployToAave(positionId);

        reactive.react(
            AbstractReactive.LogRecord({
                topic0: reactive.PRICE_EXITED_TOPIC(),
                data: abi.encode(positionId, key.toId(), int24(100))
            })
        );
        (, , uint256 originalAmount, ,) = hook.aaveDeposits(positionId);
        assertEq(originalAmount, 1e6);
    }

    function test_CronHealthSnapshot_EmitsEvent() public {
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: 180, tickUpper: 240, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );

        vm.expectEmit(true, true, true, true, address(hook));
        emit NovaraHook.ReserveHealthSnapshot(key.toId(), 0, 0, 10_000, block.timestamp);
        hook.logReserveHealth();
    }

    function test_IdleIndex_MaintainedCorrectly() public {
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: 180, tickUpper: 240, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: 300, tickUpper: 360, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: 420, tickUpper: 480, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );

        assertEq(hook.getIdlePositionCount(key.toId()), 3);

        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(200)}),
            _swapHookData(200)
        );
        assertEq(hook.getIdlePositionCount(key.toId()), 2);
    }
}
