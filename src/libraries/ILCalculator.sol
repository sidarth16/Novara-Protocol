// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

/// @title ILCalculator
/// @notice Pure helper library for estimating concentrated-liquidity impermanent loss.
/// @dev The formulas here are intentionally self-contained: no storage, no external calls,
/// and no dependency on any protocol state outside the function arguments.
library ILCalculator {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;

    /// @notice Computes impermanent loss in token1 units for a single position.
    /// @dev IL is measured as `max(0, hodlValue - positionValue(exitPrice))`.
    /// A position that was never in-range at entry is treated as having zero exposure.
    /// @param entryPrice sqrtPriceX96 captured when liquidity was added.
    /// @param exitPrice sqrtPriceX96 observed when liquidity is removed.
    /// @param tickLower Lower tick bound of the LP range.
    /// @param tickUpper Upper tick bound of the LP range.
    /// @param liquidity Position liquidity.
    /// @return ilAmount Impermanent loss denominated in token1 units.
    function computeIL(
        uint160 entryPrice,
        uint160 exitPrice,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal pure returns (uint256 ilAmount) {
        if (liquidity == 0 || tickLower >= tickUpper) return 0;

        int24 entryTick = sqrtPriceToTick(entryPrice);
        if (entryTick < tickLower || entryTick >= tickUpper) return 0;

        uint256 hodl = hodlValue(entryPrice, exitPrice, tickLower, tickUpper, liquidity);
        uint256 actual = positionValue(exitPrice, tickLower, tickUpper, liquidity);
        return hodl > actual ? hodl - actual : 0;
    }

    /// @notice Computes the current token1-denominated value of a concentrated-liquidity position.
    /// @dev The position is decomposed into its token0 and token1 amounts at `sqrtPrice`, then
    /// token0 is marked-to-market at the same price.
    /// @param sqrtPrice Current sqrtPriceX96 used for the mark.
    /// @param tickLower Lower tick bound of the LP range.
    /// @param tickUpper Upper tick bound of the LP range.
    /// @param liquidity Position liquidity.
    /// @return value Position value denominated in token1 units.
    function positionValue(uint160 sqrtPrice, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 value)
    {
        if (liquidity == 0 || tickLower >= tickUpper) return 0;

        (uint256 amount0, uint256 amount1) = _positionAmounts(sqrtPrice, tickLower, tickUpper, liquidity);
        return _token0ValueInToken1(amount0, sqrtPrice) + amount1;
    }

    /// @notice Computes the value of the tokens the LP would have held from entry through exit.
    /// @dev The entry price determines the token mix the LP was effectively exposed to at deposit.
    /// That initial token mix is then valued at `exitPrice`.
    /// @param entryPrice sqrtPriceX96 at deposit.
    /// @param exitPrice sqrtPriceX96 at withdrawal.
    /// @param tickLower Lower tick bound of the LP range.
    /// @param tickUpper Upper tick bound of the LP range.
    /// @param liquidity Position liquidity.
    /// @return value HODL value denominated in token1 units.
    function hodlValue(
        uint160 entryPrice,
        uint160 exitPrice,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal pure returns (uint256 value) {
        if (liquidity == 0 || tickLower >= tickUpper) return 0;

        (uint256 amount0, uint256 amount1) = _positionAmounts(entryPrice, tickLower, tickUpper, liquidity);
        return _token0ValueInToken1(amount0, exitPrice) + amount1;
    }

    /// @notice Converts a sqrtPriceX96 to the nearest tick.
    /// @dev TickMath returns the greatest tick such that `sqrtPriceAtTick(tick) <= sqrtPrice`.
    /// We then round to the nearest adjacent tick when the next tick is closer.
    /// @param sqrtPriceX96 Price in Q64.96 square-root form.
    /// @return tick The nearest tick to the provided price.
    function sqrtPriceToTick(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (tick == TickMath.MAX_TICK) return tick;

        uint160 lowerSqrt = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPriceX96 == lowerSqrt) return tick;

        uint160 upperSqrt = TickMath.getSqrtPriceAtTick(tick + 1);
        uint256 lowerDiff = sqrtPriceX96 - lowerSqrt;
        uint256 upperDiff = upperSqrt - sqrtPriceX96;
        return upperDiff < lowerDiff ? tick + 1 : tick;
    }

    /// @dev Returns token0 and token1 amounts for a position at a given price.
    function _positionAmounts(uint160 sqrtPrice, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtLower > sqrtUpper) (sqrtLower, sqrtUpper) = (sqrtUpper, sqrtLower);

        if (sqrtPrice <= sqrtLower) {
            amount0 = _amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        } else if (sqrtPrice < sqrtUpper) {
            amount0 = _amount0ForLiquidity(sqrtPrice, sqrtUpper, liquidity);
            amount1 = _amount1ForLiquidity(sqrtLower, sqrtPrice, liquidity);
        } else {
            amount1 = _amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        }
    }

    /// @dev Computes token0 amount for a liquidity position across a price range.
    function _amount0ForLiquidity(uint160 sqrtPriceA, uint160 sqrtPriceB, uint128 liquidity)
        private
        pure
        returns (uint256 amount0)
    {
        if (sqrtPriceA > sqrtPriceB) (sqrtPriceA, sqrtPriceB) = (sqrtPriceB, sqrtPriceA);
        if (liquidity == 0 || sqrtPriceA == 0 || sqrtPriceA == sqrtPriceB) return 0;

        amount0 = FullMath.mulDiv(uint256(liquidity) << 96, sqrtPriceB - sqrtPriceA, sqrtPriceB) / sqrtPriceA;
    }

    /// @dev Computes token1 amount for a liquidity position across a price range.
    function _amount1ForLiquidity(uint160 sqrtPriceA, uint160 sqrtPriceB, uint128 liquidity)
        private
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceA > sqrtPriceB) (sqrtPriceA, sqrtPriceB) = (sqrtPriceB, sqrtPriceA);
        if (liquidity == 0 || sqrtPriceA == sqrtPriceB) return 0;

        amount1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceB - sqrtPriceA, Q96);
    }

    /// @dev Converts token0 amount to token1 units at the provided price.
    function _token0ValueInToken1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256 value) {
        if (amount0 == 0) return 0;
        value = FullMath.mulDiv(amount0, uint256(sqrtPriceX96) << 96, Q192);
    }
}
