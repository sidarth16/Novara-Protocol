// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

import {ILCalculator} from "../src/libraries/ILCalculator.sol";

contract ILCalculatorHarness {
    function computeIL(
        uint160 entryPrice,
        uint160 exitPrice,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external pure returns (uint256) {
        return ILCalculator.computeIL(entryPrice, exitPrice, tickLower, tickUpper, liquidity);
    }

    function positionValue(uint160 sqrtPrice, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        pure
        returns (uint256)
    {
        return ILCalculator.positionValue(sqrtPrice, tickLower, tickUpper, liquidity);
    }

    function hodlValue(
        uint160 entryPrice,
        uint160 exitPrice,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external pure returns (uint256) {
        return ILCalculator.hodlValue(entryPrice, exitPrice, tickLower, tickUpper, liquidity);
    }

    function sqrtPriceToTick(uint160 sqrtPriceX96) external pure returns (int24) {
        return ILCalculator.sqrtPriceToTick(sqrtPriceX96);
    }
}

contract ILCalculatorTest is Test {
    ILCalculatorHarness internal calc;

    function setUp() public {
        calc = new ILCalculatorHarness();
    }

    function test_IL_ZeroWhenPriceUnchanged() public view {
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        uint256 ilAmount = calc.computeIL(price, price, -120, 120, 1_000_000);
        assertEq(ilAmount, 0);
    }

    function test_IL_PositiveWhenPriceFalls() public view {
        uint160 entry = TickMath.getSqrtPriceAtTick(0);
        uint160 exit = TickMath.getSqrtPriceAtTick(-1_000);
        uint256 ilAmount = calc.computeIL(entry, exit, -500, 500, 1e18);
        assertGt(ilAmount, 0);
    }

    function test_IL_PositiveWhenPriceRises() public view {
        uint160 entry = TickMath.getSqrtPriceAtTick(0);
        uint160 exit = TickMath.getSqrtPriceAtTick(1_000);
        uint256 ilAmount = calc.computeIL(entry, exit, -500, 500, 1e18);
        assertGt(ilAmount, 0);
    }

    function test_IL_ZeroWhenOutOfRangeAtEntry() public view {
        uint160 entry = TickMath.getSqrtPriceAtTick(900);
        uint160 exit = TickMath.getSqrtPriceAtTick(0);
        uint256 ilAmount = calc.computeIL(entry, exit, -120, 120, 1_000_000);
        assertEq(ilAmount, 0);
    }

    function test_HodlValue_GreaterThanPosition_OnVolatility() public view {
        uint160 entry = TickMath.getSqrtPriceAtTick(0);
        uint160 exit = TickMath.getSqrtPriceAtTick(2_000);
        uint256 hodl = calc.hodlValue(entry, exit, -500, 500, 1e18);
        uint256 value = calc.positionValue(exit, -500, 500, 1e18);
        assertGt(hodl, value);
    }

    function test_PositionValue_ZeroLiquidity() public view {
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        assertEq(calc.positionValue(price, -120, 120, 0), 0);
    }

    function test_SqrtPriceToTick_RoundsToNearest() public view {
        uint160 lower = TickMath.getSqrtPriceAtTick(10);
        uint160 upper = TickMath.getSqrtPriceAtTick(11);
        uint160 mid = uint160(uint256(lower) + ((uint256(upper) - uint256(lower)) * 9) / 10);
        assertEq(calc.sqrtPriceToTick(mid), 11);
    }
}
