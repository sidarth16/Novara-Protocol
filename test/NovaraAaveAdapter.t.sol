// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

import {IAavePoolLike} from "../src/interfaces/IAavePoolLike.sol";
import {NovaraAaveAdapter} from "../src/NovaraAaveAdapter.sol";
import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraReserve} from "../src/NovaraReserve.sol";

contract MockAavePoolLike is IAavePoolLike {
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

    function balanceOf(address account, address asset) external view returns (uint256) {
        return balances[account][asset];
    }
}

contract NovaraAaveAdapterTest is Test {
    using PoolIdLibrary for PoolKey;

    MockAavePoolLike internal pool;
    NovaraAaveAdapter internal adapter;
    NovaraHook internal hook;
    NovaraReserve internal reserve;
    PoolKey internal key;
    address internal owner = address(0xA11CE);
    address internal token0 = address(0x1111);
    address internal token1 = address(0x2222);

    function setUp() public {
        pool = new MockAavePoolLike();
        hook = new NovaraHook();
        reserve = new NovaraReserve(address(hook));
        adapter = new NovaraAaveAdapter(address(pool), address(hook));
        hook.setReserve(address(reserve));
        hook.setAaveAdapter(address(adapter));
        hook.setReactiveContract(address(this));
        hook.setChainlinkForwarder(address(this));

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

    function test_OnlyHookCanDeposit() public {
        vm.expectRevert(NovaraAaveAdapter.OnlyHook.selector);
        adapter.deposit(token0, 100 ether);
    }

    function test_Deposit_TracksPrincipal() public {
        vm.prank(address(hook));
        uint256 aTokenAmount = adapter.deposit(token0, 1_000 ether);

        assertEq(aTokenAmount, 1_000 ether);
        (address asset, uint256 originalAmount, uint256 storedATokenAmount, uint256 depositTimestamp, address aToken) =
            adapter.deposits(address(0xA7001));
        assertEq(asset, token0);
        assertEq(originalAmount, 1_000 ether);
        assertEq(storedATokenAmount, 1_000 ether);
        assertGt(depositTimestamp, 0);
        assertEq(aToken, address(0xA7001));
    }

    function test_GetAPY_ReturnsNonZero() public view {
        assertGt(adapter.currentAPY(token0), 0);
    }

    function test_CanDeposit_ReturnsTrueForLiquidMarket() public view {
        assertTrue(adapter.canDeposit(token0, 1_000 ether));
    }

    function test_CanDeposit_ReturnsFalseWhenLiquidityInsufficient() public {
        pool.setReserve(token0, 100 ether, 40_000_000_000_000_000_000_000_000, address(0xA7001));
        assertFalse(adapter.canDeposit(token0, 1_000 ether));
    }

    function test_YieldAccrues_OverTime() public {
        vm.prank(address(hook));
        adapter.deposit(token0, 1_000 ether);

        vm.warp(block.timestamp + 30 days);
        uint256 yieldAmount = adapter.getYieldAccrued(address(0xA7001), 1_000 ether);
        assertGt(yieldAmount, 0);
    }

    function test_Withdraw_ReturnsPrincipalPlusYield() public {
        vm.prank(address(hook));
        adapter.deposit(token0, 1_000 ether);

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(hook));
        uint256 received = adapter.withdraw(token0, 1_000 ether);

        assertGt(received, 1_000 ether);
        (address asset, uint256 originalAmount, uint256 storedATokenAmount, uint256 depositTimestamp, address aToken) =
            adapter.deposits(address(0xA7001));
        assertEq(asset, address(0));
        assertEq(originalAmount, 0);
        assertEq(storedATokenAmount, 0);
        assertEq(depositTimestamp, 0);
        assertEq(aToken, address(0));
    }

    function test_DeployToAave_OnStateChange() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

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

        hook.deployToAave(keccak256(abi.encodePacked(owner, key.toId(), tickLower, tickUpper)));

        (, , uint256 originalAmount, , uint256 depositTimestamp) =
            hook.aaveDeposits(keccak256(abi.encodePacked(owner, key.toId(), tickLower, tickUpper)));
        assertEq(originalAmount, 1e6);
        assertGt(depositTimestamp, 0);
    }

    function test_RecallFromAave_YieldToReserve() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;
        bytes32 positionId = keccak256(abi.encodePacked(owner, key.toId(), tickLower, tickUpper));

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

        vm.warp(block.timestamp + 30 days);
        hook.recallFromAave(positionId);

        (, , uint256 originalAmount, ,) = hook.aaveDeposits(positionId);
        assertEq(originalAmount, 0);

        (uint256 assets,,) = reserve.reserves(key.toId());
        assertGt(assets, 0);
    }

    function test_DepositSkipped_WhenLiquidityInsufficient() public {
        pool.setReserve(token0, 0, 40_000_000_000_000_000_000_000_000, address(0xA7001));

        int24 tickLower = -60;
        int24 tickUpper = 60;
        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(-120, _profile(true, false, 2500))
        );

        (, , uint256 originalAmount, ,) = hook.aaveDeposits(keccak256(abi.encodePacked(owner, key.toId(), tickLower, tickUpper)));
        assertEq(originalAmount, 0);
    }
}
