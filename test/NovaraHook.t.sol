// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

import {NovaraHook} from "../src/NovaraHook.sol";
import {NovaraReserve} from "../src/NovaraReserve.sol";

contract NovaraHookTest is Test {
    using PoolIdLibrary for PoolKey;

    event PositionCreated(
        bytes32 indexed positionId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint160 entryPrice,
        uint256 timestamp
    );

    event PositionStateChanged(bytes32 indexed positionId, NovaraHook.PositionState oldState, NovaraHook.PositionState newState, int24 currentTick);

    event PositionExited(bytes32 indexed positionId, address indexed owner, uint256 timestamp);

    NovaraHook internal hook;
    NovaraReserve internal reserve;
    PoolKey internal key;
    address internal owner = address(0xA11CE);
    address internal otherOwner = address(0xB0B);

    function setUp() public {
        hook = new NovaraHook();
        reserve = new NovaraReserve(address(hook));
        hook.setReserve(address(reserve));
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
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

    function _position(
        address account,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (NovaraHook.Position memory) {
        return hook.getPosition(_positionId(account, tickLower, tickUpper));
    }

    function test_HookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        bool beforeInitialize = permissions.beforeInitialize;
        bool afterInitialize = permissions.afterInitialize;
        bool beforeAddLiquidity = permissions.beforeAddLiquidity;
        bool afterAddLiquidity = permissions.afterAddLiquidity;
        bool beforeRemoveLiquidity = permissions.beforeRemoveLiquidity;
        bool afterRemoveLiquidity = permissions.afterRemoveLiquidity;
        bool beforeSwap = permissions.beforeSwap;
        bool afterSwap = permissions.afterSwap;
        bool beforeDonate = permissions.beforeDonate;
        bool afterDonate = permissions.afterDonate;
        bool beforeSwapReturnDelta = permissions.beforeSwapReturnDelta;
        bool afterSwapReturnDelta = permissions.afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta = permissions.afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta = permissions.afterRemoveLiquidityReturnDelta;

        assertFalse(beforeInitialize);
        assertFalse(afterInitialize);
        assertFalse(beforeAddLiquidity);
        assertTrue(afterAddLiquidity);
        assertTrue(beforeRemoveLiquidity);
        assertFalse(afterRemoveLiquidity);
        assertTrue(beforeSwap);
        assertFalse(afterSwap);
        assertFalse(beforeDonate);
        assertFalse(afterDonate);
        assertFalse(beforeSwapReturnDelta);
        assertFalse(afterSwapReturnDelta);
        assertFalse(afterAddLiquidityReturnDelta);
        assertFalse(afterRemoveLiquidityReturnDelta);
    }

    function test_ReserveLiabilityRecordedOnAdd() public {
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

        (, uint256 liabilities, uint256 coverage) = reserve.reserves(key.toId());
        assertGt(liabilities, 0);
        assertEq(coverage, 0);
    }

    function test_PositionCreated_InRange() public {
        int24 currentTick = 0;
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 1_000_000;
        bytes32 positionId = _positionId(owner, tickLower, tickUpper);
        NovaraHook.ProtectionProfile memory profile = _profile(true, false, 2500);
        uint160 entryPrice = TickMath.getSqrtPriceAtTick(currentTick);

        vm.expectEmit(true, true, true, true, address(hook));
        emit PositionCreated(positionId, owner, key.toId(), tickLower, tickUpper, entryPrice, block.timestamp);

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(currentTick, profile)
        );

        NovaraHook.Position memory position = _position(owner, tickLower, tickUpper);
        assertEq(position.owner, owner);
        assertEq(position.tickLower, tickLower);
        assertEq(position.tickUpper, tickUpper);
        assertEq(position.liquidity, liquidity);
        assertEq(position.entryPrice, entryPrice);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.ACTIVE));

        NovaraHook.ProtectionProfile memory storedProfile = hook.getProtectionProfile(positionId);
        assertTrue(storedProfile.autoRedeploy);
        assertFalse(storedProfile.autoExit);
        assertEq(storedProfile.exitCoverageThreshold, 2500);
    }

    function test_PositionCreated_OutOfRange() public {
        int24 currentTick = 0;
        int24 tickLower = 180;
        int24 tickUpper = 240;
        uint128 liquidity = 2_500_000;

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(currentTick, _profile(false, true, 3000))
        );

        NovaraHook.Position memory position = _position(owner, tickLower, tickUpper);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.IDLE));
    }

    function test_StateChange_ActiveToIdle() public {
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

        bytes32 positionId = _positionId(owner, tickLower, tickUpper);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PositionStateChanged(positionId, NovaraHook.PositionState.ACTIVE, NovaraHook.PositionState.IDLE, 100);

        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );

        NovaraHook.Position memory position = _position(owner, tickLower, tickUpper);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.IDLE));
    }

    function test_StateChange_IdleToActive() public {
        int24 tickLower = 180;
        int24 tickUpper = 240;

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );

        bytes32 positionId = _positionId(owner, tickLower, tickUpper);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PositionStateChanged(positionId, NovaraHook.PositionState.IDLE, NovaraHook.PositionState.ACTIVE, 200);

        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(200)}),
            _swapHookData(200)
        );

        NovaraHook.Position memory position = _position(owner, tickLower, tickUpper);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.ACTIVE));
    }

    function test_StateChange_DoesNotFireIfAlreadyIdle() public {
        int24 tickLower = 180;
        int24 tickUpper = 240;

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(false, false, 0))
        );

        vm.recordLogs();
        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);

        NovaraHook.Position memory position = _position(owner, tickLower, tickUpper);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.IDLE));
    }

    function test_PositionExited() public {
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

        (, uint256 liabilitiesBefore, ) = reserve.reserves(key.toId());
        assertGt(liabilitiesBefore, 0);

        bytes32 positionId = _positionId(owner, tickLower, tickUpper);
        vm.expectEmit(true, true, false, true, address(hook));
        emit PositionExited(positionId, owner, block.timestamp);

        hook.beforeRemoveLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1e6, salt: bytes32(0)}),
            bytes("")
        );

        NovaraHook.Position memory position = _position(owner, tickLower, tickUpper);
        assertEq(uint8(position.state), uint8(NovaraHook.PositionState.EXITED));

        (, uint256 liabilitiesAfter, uint256 coverageAfter) = reserve.reserves(key.toId());
        assertEq(liabilitiesAfter, 0);
        assertEq(coverageAfter, 10_000);
    }

    function test_CannotExitTwice() public {
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

        hook.beforeRemoveLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1e6, salt: bytes32(0)}),
            bytes("")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                NovaraHook.PositionAlreadyExited.selector, _positionId(owner, tickLower, tickUpper)
            )
        );
        hook.beforeRemoveLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1e6, salt: bytes32(0)}),
            bytes("")
        );
    }

    function test_MultiplePositions_SamePool() public {
        int24 tickLowerA = -60;
        int24 tickUpperA = 60;
        int24 tickLowerB = 180;
        int24 tickUpperB = 240;

        hook.afterAddLiquidity(
            owner,
            key,
            ModifyLiquidityParams({tickLower: tickLowerA, tickUpper: tickUpperA, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(true, false, 2500))
        );

        hook.afterAddLiquidity(
            otherOwner,
            key,
            ModifyLiquidityParams({tickLower: tickLowerB, tickUpper: tickUpperB, liquidityDelta: 1e6, salt: bytes32(0)}),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            _addHookData(0, _profile(false, true, 3000))
        );

        vm.expectEmit(true, true, true, true, address(hook));
        emit PositionStateChanged(
            _positionId(owner, tickLowerA, tickUpperA),
            NovaraHook.PositionState.ACTIVE,
            NovaraHook.PositionState.IDLE,
            100
        );

        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );

        NovaraHook.Position memory positionA = _position(owner, tickLowerA, tickUpperA);
        NovaraHook.Position memory positionB = _position(otherOwner, tickLowerB, tickUpperB);
        assertEq(uint8(positionA.state), uint8(NovaraHook.PositionState.IDLE));
        assertEq(uint8(positionB.state), uint8(NovaraHook.PositionState.IDLE));
    }

    function test_ReserveLiabilityTracksStateTransitions() public {
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

        (, uint256 liabilitiesInRange, ) = reserve.reserves(key.toId());
        assertGt(liabilitiesInRange, 0);

        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)}),
            _swapHookData(100)
        );

        (, uint256 liabilitiesOutOfRange, ) = reserve.reserves(key.toId());
        assertEq(liabilitiesOutOfRange, 0);

        hook.beforeSwap(
            owner,
            key,
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)}),
            _swapHookData(0)
        );

        (, uint256 liabilitiesBackInRange, ) = reserve.reserves(key.toId());
        assertGt(liabilitiesBackInRange, 0);
    }
}
