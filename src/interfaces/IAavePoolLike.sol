// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAavePoolLike
/// @notice Minimal Aave pool surface used by Novara Day 3.
/// @dev This mirrors only the subset needed for local integration tests and can be
/// swapped for the official Aave IPool interface later.
interface IAavePoolLike {
    struct ReserveData {
        uint256 availableLiquidity;
        uint128 currentLiquidityRate;
        address aTokenAddress;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function getReserveData(address asset) external view returns (ReserveData memory);
}
