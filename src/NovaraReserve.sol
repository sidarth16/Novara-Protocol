// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";

import {ReserveMath} from "./libraries/ReserveMath.sol";

/// @title NovaraReserve
/// @notice Pure reserve accounting for Novara Day 2.
/// @dev This contract does not move tokens, does not talk to Aave, and does not depend on
/// Reactive/Chainlink. It only tracks reserve balances and liabilities.
contract NovaraReserve {
    struct Reserve {
        uint256 totalAssets;
        uint256 totalLiabilities;
        uint256 coverageRatioBPS;
    }

    mapping(PoolId => Reserve) public reserves;

    address public immutable hook;

    mapping(PoolId => mapping(bytes32 => uint256)) internal liabilitiesByPosition;

    event ReserveUpdated(PoolId indexed poolId, uint256 totalAssets, uint256 coverageRatioBPS);
    /// @dev Day 2 uses this as an accounting event; actual payout transfers are added later.
    event ILCompensated(bytes32 indexed positionId, uint256 ilAmount, uint256 payoutAmount, uint256 coverageRatioBPS);

    error OnlyHook();

    constructor(address hook_) {
        require(hook_ != address(0), "hook zero");
        hook = hook_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /// @notice Increases reserve assets for a pool.
    function deposit(PoolId poolId, uint256 amount) external onlyHook {
        if (amount == 0) {
            _syncCoverage(poolId);
            return;
        }

        Reserve storage reserve = reserves[poolId];
        reserve.totalAssets += amount;
        _syncCoverage(poolId);
        emit ReserveUpdated(poolId, reserve.totalAssets, reserve.coverageRatioBPS);
    }

    /// @notice Decreases reserve assets for a pool and returns the actual withdrawn amount.
    function withdraw(PoolId poolId, uint256 amount) external onlyHook returns (uint256 withdrawn) {
        Reserve storage reserve = reserves[poolId];
        withdrawn = amount > reserve.totalAssets ? reserve.totalAssets : amount;
        reserve.totalAssets -= withdrawn;
        _syncCoverage(poolId);
        emit ReserveUpdated(poolId, reserve.totalAssets, reserve.coverageRatioBPS);
    }

    /// @notice Records or updates the estimated IL exposure for a position.
    /// @dev The position liability is stored so it can later be removed cleanly.
    function recordLiability(PoolId poolId, bytes32 positionId, uint256 ilExposure) external onlyHook {
        Reserve storage reserve = reserves[poolId];
        uint256 previous = liabilitiesByPosition[poolId][positionId];

        if (previous != ilExposure) {
            if (previous > 0) reserve.totalLiabilities -= previous;
            liabilitiesByPosition[poolId][positionId] = ilExposure;
            reserve.totalLiabilities += ilExposure;
        }

        _syncCoverage(poolId);
        emit ReserveUpdated(poolId, reserve.totalAssets, reserve.coverageRatioBPS);
    }

    /// @notice Clears the estimated IL exposure for a position.
    /// @dev Emits an ILCompensated bookkeeping event using the current coverage ratio.
    function clearLiability(PoolId poolId, bytes32 positionId) external onlyHook {
        Reserve storage reserve = reserves[poolId];
        uint256 exposure = liabilitiesByPosition[poolId][positionId];
        if (exposure == 0) {
            _syncCoverage(poolId);
            emit ReserveUpdated(poolId, reserve.totalAssets, reserve.coverageRatioBPS);
            return;
        }

        uint256 coverageBeforeClear = reserve.coverageRatioBPS;
        uint256 payoutAmount = ReserveMath.computeMaxPayout(exposure, coverageBeforeClear);
        if (reserve.totalLiabilities >= exposure) {
            reserve.totalLiabilities -= exposure;
        } else {
            reserve.totalLiabilities = 0;
        }
        delete liabilitiesByPosition[poolId][positionId];

        _syncCoverage(poolId);
        emit ILCompensated(positionId, exposure, payoutAmount, coverageBeforeClear);
        emit ReserveUpdated(poolId, reserve.totalAssets, reserve.coverageRatioBPS);
    }

    /// @notice Returns the current reserve coverage ratio in basis points.
    function getCoverageRatio(PoolId poolId) external view returns (uint256) {
        return reserves[poolId].coverageRatioBPS;
    }

    /// @notice Returns the maximum payout allowed for the given IL amount.
    function getMaxPayout(PoolId poolId, uint256 ilAmount) external view returns (uint256) {
        return ReserveMath.computeMaxPayout(ilAmount, reserves[poolId].coverageRatioBPS);
    }

    function _syncCoverage(PoolId poolId) internal {
        Reserve storage reserve = reserves[poolId];
        reserve.coverageRatioBPS = ReserveMath.computeCoverageRatio(reserve.totalAssets, reserve.totalLiabilities);
    }
}
