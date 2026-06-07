// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ReserveMath} from "../src/libraries/ReserveMath.sol";

contract ReserveMathHarness {
    function computeCoverageRatio(uint256 reserveAssets, uint256 totalLiabilities) external pure returns (uint256) {
        return ReserveMath.computeCoverageRatio(reserveAssets, totalLiabilities);
    }

    function computeMaxPayout(uint256 ilAmount, uint256 coverageRatioBPS) external pure returns (uint256) {
        return ReserveMath.computeMaxPayout(ilAmount, coverageRatioBPS);
    }

    function computePremiumRate(uint256 rollingVolatilityBPS) external pure returns (uint256) {
        return ReserveMath.computePremiumRate(rollingVolatilityBPS);
    }

    function computeVolatilityMultiplier(uint256 tickCrossingsLast100Swaps) external pure returns (uint256) {
        return ReserveMath.computeVolatilityMultiplier(tickCrossingsLast100Swaps);
    }
}

contract ReserveMathTest is Test {
    ReserveMathHarness internal math;

    function setUp() public {
        math = new ReserveMathHarness();
    }

    function test_PremiumRate_MinAtLowVolatility() public view {
        assertEq(math.computePremiumRate(0), 50);
    }

    function test_PremiumRate_MaxAtHighVolatility() public view {
        assertEq(math.computePremiumRate(10_000), 125);
    }

    function test_CoverageRatio_100_WhenNoLiabilities() public view {
        assertEq(math.computeCoverageRatio(0, 0), 10_000);
    }

    function test_CoverageRatio_Proportional() public view {
        assertEq(math.computeCoverageRatio(500, 1_000), 5_000);
    }

    function test_CoverageRatio_CappedAt100() public view {
        assertEq(math.computeCoverageRatio(10_000, 1), 10_000);
    }

    function test_MaxPayout_CappedByCoverage() public view {
        assertEq(math.computeMaxPayout(100, 5_000), 50);
    }

    function test_MaxPayout_FullCoverageReturnsFullIL() public view {
        assertEq(math.computeMaxPayout(100, 10_000), 100);
    }

    function test_VolatilityMultiplier_MinAtZeroCrossings() public view {
        assertEq(math.computeVolatilityMultiplier(0), 100);
    }

    function test_VolatilityMultiplier_MaxAtHundredCrossings() public view {
        assertEq(math.computeVolatilityMultiplier(100), 250);
    }

    function test_VolatilityMultiplier_CappedAboveHundred() public view {
        assertEq(math.computeVolatilityMultiplier(1_000), 250);
    }
}
