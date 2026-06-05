// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/libraries/FullMath.sol";

/// @title ReserveMath
/// @notice Pure helper library for reserve coverage and adaptive premium math.
/// @dev All outputs are expressed in basis points unless explicitly stated otherwise.
library ReserveMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Computes reserve coverage as a BPS value.
    /// @dev If liabilities are zero, coverage is treated as 100%.
    /// The result is capped at 10_000 BPS so it never reports more than full coverage.
    /// @param reserveAssets Total assets currently accounted to the reserve.
    /// @param totalLiabilities Total estimated impermanent-loss exposure.
    /// @return ratioBPS Coverage ratio in basis points.
    function computeCoverageRatio(uint256 reserveAssets, uint256 totalLiabilities)
        internal
        pure
        returns (uint256 ratioBPS)
    {
        if (totalLiabilities == 0) return BPS;

        ratioBPS = FullMath.mulDiv(reserveAssets, BPS, totalLiabilities);
        if (ratioBPS > BPS) ratioBPS = BPS;
    }

    /// @notice Computes the maximum payout allowed for a given IL amount at a given coverage level.
    /// @dev The payout is the IL amount scaled by the current coverage ratio.
    /// @param ilAmount Impermanent loss amount being considered.
    /// @param coverageRatioBPS Coverage ratio in basis points.
    /// @return payout Maximum payout in the same units as `ilAmount`.
    function computeMaxPayout(uint256 ilAmount, uint256 coverageRatioBPS)
        internal
        pure
        returns (uint256 payout)
    {
        if (ilAmount == 0 || coverageRatioBPS == 0) return 0;
        if (coverageRatioBPS >= BPS) return ilAmount;
        payout = FullMath.mulDiv(ilAmount, coverageRatioBPS, BPS);
        if (payout > ilAmount) payout = ilAmount;
    }

    /// @notice Computes the premium rate to route from swap fees to the reserve.
    /// @dev `rollingVolatilityBPS` is treated as a normalized volatility score in the range
    /// `[0, 10_000]`, where 0 means calm and 10_000 means maximum observed volatility.
    /// The output ranges from 50 BPS to 125 BPS.
    /// @param rollingVolatilityBPS Normalized rolling volatility score.
    /// @return premiumRateBPS Premium rate in basis points.
    function computePremiumRate(uint256 rollingVolatilityBPS) internal pure returns (uint256 premiumRateBPS) {
        uint256 clampedVolatility = rollingVolatilityBPS > BPS ? BPS : rollingVolatilityBPS;
        premiumRateBPS = 50 + (clampedVolatility * 75) / BPS;
    }

    /// @notice Converts the last-100-swap tick-crossing count into a BPS multiplier.
    /// @dev 0 crossings => 100 BPS (1.0x), 100 crossings or more => 250 BPS (2.5x).
    /// @param tickCrossingsLast100Swaps Number of tick crossings observed in the last 100 swaps.
    /// @return multiplierBPS Volatility multiplier in basis points.
    function computeVolatilityMultiplier(uint256 tickCrossingsLast100Swaps)
        internal
        pure
        returns (uint256 multiplierBPS)
    {
        uint256 clampedCrossings = tickCrossingsLast100Swaps > 100 ? 100 : tickCrossingsLast100Swaps;
        multiplierBPS = 100 + (clampedCrossings * 150) / 100;
    }
}
