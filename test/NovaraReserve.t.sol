// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";

import {NovaraReserve} from "../src/NovaraReserve.sol";

contract NovaraReserveTest is Test {
    using PoolIdLibrary for PoolKey;

    NovaraReserve internal reserve;
    PoolId internal poolId;

    event ReserveUpdated(PoolId indexed poolId, uint256 totalAssets, uint256 coverageRatioBPS);

    function setUp() public {
        reserve = new NovaraReserve(address(this));
        poolId = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        }).toId();
    }

    function test_OnlyHookCanDeposit() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(NovaraReserve.OnlyHook.selector);
        reserve.deposit(poolId, 100);
    }

    function test_ReserveGrowsAfterDeposit() public {
        vm.expectEmit(true, true, true, true, address(reserve));
        emit ReserveUpdated(poolId, 250, 10_000);

        reserve.deposit(poolId, 250);

        (uint256 assets, uint256 liabilities, uint256 coverage) = reserve.reserves(poolId);
        assertEq(assets, 250);
        assertEq(liabilities, 0);
        assertEq(coverage, 10_000);
    }

    function test_WithdrawingReducesReserve() public {
        reserve.deposit(poolId, 500);
        uint256 withdrawn = reserve.withdraw(poolId, 200);

        assertEq(withdrawn, 200);
        (uint256 assets,,) = reserve.reserves(poolId);
        assertEq(assets, 300);
    }

    function test_WithdrawingMoreThanAssetsCapsAtReserveBalance() public {
        reserve.deposit(poolId, 100);
        uint256 withdrawn = reserve.withdraw(poolId, 500);

        assertEq(withdrawn, 100);
        (uint256 assets,,) = reserve.reserves(poolId);
        assertEq(assets, 0);
    }

    function test_RecordLiability_UpdatesCoverage() public {
        reserve.deposit(poolId, 500);
        reserve.recordLiability(poolId, bytes32(uint256(1)), 1_000);

        (uint256 assets, uint256 liabilities, uint256 coverage) = reserve.reserves(poolId);
        assertEq(assets, 500);
        assertEq(liabilities, 1_000);
        assertEq(coverage, 5_000);
    }

    function test_UpdateLiability_ReplacesPreviousExposure() public {
        reserve.deposit(poolId, 900);
        bytes32 positionId = bytes32(uint256(7));
        reserve.recordLiability(poolId, positionId, 300);
        reserve.recordLiability(poolId, positionId, 600);

        (uint256 assets, uint256 liabilities, uint256 coverage) = reserve.reserves(poolId);
        assertEq(assets, 900);
        assertEq(liabilities, 600);
        assertEq(coverage, 10_000);
    }

    function test_ClearLiability_ReducesExposure() public {
        reserve.deposit(poolId, 500);
        bytes32 positionId = bytes32(uint256(9));
        reserve.recordLiability(poolId, positionId, 400);
        reserve.clearLiability(poolId, positionId);

        (uint256 assets, uint256 liabilities, uint256 coverage) = reserve.reserves(poolId);
        assertEq(assets, 500);
        assertEq(liabilities, 0);
        assertEq(coverage, 10_000);
    }

    function test_GetMaxPayout_UsesCoverage() public {
        reserve.deposit(poolId, 500);
        reserve.recordLiability(poolId, bytes32(uint256(11)), 1_000);
        assertEq(reserve.getMaxPayout(poolId, 100), 50);
    }

    function test_ClearLiability_IsNoOpIfMissing() public {
        reserve.deposit(poolId, 500);
        reserve.clearLiability(poolId, bytes32(uint256(123)));

        (uint256 assets, uint256 liabilities, uint256 coverage) = reserve.reserves(poolId);
        assertEq(assets, 500);
        assertEq(liabilities, 0);
        assertEq(coverage, 10_000);
    }
}
