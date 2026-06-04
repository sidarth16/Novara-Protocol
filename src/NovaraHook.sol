// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

import {BaseHook} from "./base/BaseHook.sol";
import {NovaraAaveAdapter} from "./NovaraAaveAdapter.sol";
import {ILCalculator} from "./libraries/ILCalculator.sol";
import {NovaraReserve} from "./NovaraReserve.sol";

contract NovaraHook is BaseHook {
    /// @notice Lifecycle status for a protected LP position.
    enum PositionState {
        ACTIVE,
        IDLE,
        EXITED
    }

    /// @notice Position metadata tracked per LP range.
    struct Position {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint160 entryPrice;
        uint256 entryTimestamp;
        PositionState state;
    }

    /// @notice LP-selected protection preferences stored alongside the position.
    struct ProtectionProfile {
        bool autoRedeploy;
        bool autoExit;
        uint256 exitCoverageThreshold;
    }

    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => ProtectionProfile) public profiles;
    mapping(PoolId => bytes32[]) internal poolPositions;
    NovaraReserve public reserve;
    NovaraAaveAdapter public aaveAdapter;
    address public immutable deployer;

    /// @notice Aave bookkeeping for positions that are temporarily deployed outside Uniswap.
    struct AaveDeposit {
        address token;
        address aToken;
        uint256 originalAmount;
        uint256 aTokenAmount;
        uint256 depositTimestamp;
    }

    mapping(bytes32 => AaveDeposit) public aaveDeposits;

    // TODO(Day 2): wire reserve accounting and premium routing here.
    // TODO(Day 3): route idle positions into Aave when they become IDLE.
    // TODO(Day 4): reconnect Reactive callbacks for range re-entry automation.
    event PositionCreated(
        bytes32 indexed positionId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint160 entryPrice,
        uint256 timestamp
    );

    event PositionStateChanged(bytes32 indexed positionId, PositionState oldState, PositionState newState, int24 currentTick);

    event AaveDeployed(
        bytes32 indexed positionId,
        address indexed token,
        uint256 amount,
        uint256 aTokenAmount,
        uint256 timestamp
    );

    event AaveRecalled(
        bytes32 indexed positionId,
        address indexed token,
        uint256 originalAmount,
        uint256 yieldEarned,
        uint256 timestamp
    );

    event AaveDepositSkipped(bytes32 indexed positionId, string reason);

    // TODO(Day 5): emit reserve-backed payout telemetry once IL compensation exists.
    event PositionExited(bytes32 indexed positionId, address indexed owner, uint256 timestamp);

    error PositionAlreadyExists(bytes32 positionId);
    error PositionNotFound(bytes32 positionId);
    error PositionAlreadyExited(bytes32 positionId);
    error ReserveAlreadyConfigured();
    error ReserveAddressZero();
    error AaveAlreadyConfigured();
    error AaveAddressZero();
    error NotDeployer();

    constructor() {
        deployer = msg.sender;
    }

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert NotDeployer();
        _;
    }

    /// @notice Configures the reserve contract once after deployment.
    function setReserve(address reserve_) external onlyDeployer {
        if (reserve_ == address(0)) revert ReserveAddressZero();
        if (address(reserve) != address(0)) revert ReserveAlreadyConfigured();
        reserve = NovaraReserve(reserve_);
    }

    /// @notice Configures the Aave adapter once after deployment.
    function setAaveAdapter(address aaveAdapter_) external onlyDeployer {
        if (aaveAdapter_ == address(0)) revert AaveAddressZero();
        if (address(aaveAdapter) != address(0)) revert AaveAlreadyConfigured();
        aaveAdapter = NovaraAaveAdapter(aaveAdapter_);
    }

    function getPosition(bytes32 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getProtectionProfile(bytes32 positionId) external view returns (ProtectionProfile memory) {
        return profiles[positionId];
    }

    /// @notice Enables only the Day 1 hook callbacks.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Creates and snapshots a position when liquidity is added.
    /// @dev `hookData` is expected to encode `(int24 currentTick, ProtectionProfile profile)` for Day 1 tests.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        (int24 currentTick, ProtectionProfile memory profile) = _decodeAddHookData(hookData);
        uint128 liquidity = params.liquidityDelta > 0 ? uint128(uint256(params.liquidityDelta)) : 0;
        bytes32 positionId =
            addPosition(sender, key.toId(), key, params.tickLower, params.tickUpper, liquidity, currentTick, profile);
        if (!_isInRange(currentTick, params.tickLower, params.tickUpper)) {
            _deployToAave(key.toId(), key, positionId, currentTick);
        }
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Detects range crossings and flips ACTIVE/IDLE state accordingly.
    /// @dev `hookData` is expected to encode `int24 currentTick` for Day 1 tests.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int24 currentTick = _decodeSwapHookData(hookData);
        bytes32[] storage ids = poolPositions[key.toId()];

        for (uint256 i = 0; i < ids.length; i++) {
            bytes32 positionId = ids[i];
            Position storage position = positions[positionId];
            if (position.owner == address(0) || position.state == PositionState.EXITED) continue;

            bool inRange = _isInRange(currentTick, position.tickLower, position.tickUpper);
            if (position.state == PositionState.ACTIVE && !inRange) {
                position.state = PositionState.IDLE;
                emit PositionStateChanged(positionId, PositionState.ACTIVE, PositionState.IDLE, currentTick);
                if (address(reserve) != address(0)) {
                    reserve.recordLiability(key.toId(), positionId, 0);
                }
                _deployToAave(key.toId(), key, positionId, currentTick);
            } else if (position.state == PositionState.IDLE && inRange) {
                position.state = PositionState.ACTIVE;
                emit PositionStateChanged(positionId, PositionState.IDLE, PositionState.ACTIVE, currentTick);
                _recallFromAave(key.toId(), key, positionId, currentTick);
                if (address(reserve) != address(0)) {
                    uint256 exposure = ILCalculator.positionValue(
                        TickMath.getSqrtPriceAtTick(currentTick), position.tickLower, position.tickUpper, position.liquidity
                    );
                    reserve.recordLiability(key.toId(), positionId, exposure);
                }
            }
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Marks a position as exited when liquidity is removed.
    /// @dev TODO(Day 2): compute IL and payout scheduling here.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        bytes32 positionId = _positionId(sender, key.toId(), params.tickLower, params.tickUpper);
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound(positionId);
        if (position.state == PositionState.EXITED) revert PositionAlreadyExited(positionId);

        int24 currentTick = _decodeRemoveHookData(hookData, position.entryPrice);
        uint160 exitPrice = TickMath.getSqrtPriceAtTick(currentTick);
        uint256 ilAmount =
            ILCalculator.computeIL(position.entryPrice, exitPrice, position.tickLower, position.tickUpper, position.liquidity);

        position.state = PositionState.EXITED;
        emit PositionExited(positionId, sender, block.timestamp);

        if (address(reserve) != address(0)) {
            if (ilAmount > 0) {
                reserve.recordLiability(key.toId(), positionId, ilAmount);
            }
            reserve.clearLiability(key.toId(), positionId);
        }

        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice Computes the stable ID for a position.
    function _positionId(address owner, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, poolId, tickLower, tickUpper));
    }

    function _isInRange(int24 currentTick, int24 tickLower, int24 tickUpper) internal pure returns (bool) {
        return currentTick >= tickLower && currentTick < tickUpper;
    }

    function _decodeAddHookData(bytes calldata hookData)
        internal
        pure
        returns (int24 currentTick, ProtectionProfile memory profile)
    {
        if (hookData.length == 0) {
            return (0, ProtectionProfile({autoRedeploy: false, autoExit: false, exitCoverageThreshold: 0}));
        }
        return abi.decode(hookData, (int24, ProtectionProfile));
    }

    function _decodeSwapHookData(bytes calldata hookData) internal pure returns (int24 currentTick) {
        if (hookData.length == 0) return 0;
        return abi.decode(hookData, (int24));
    }

    function _decodeRemoveHookData(bytes calldata hookData, uint160 fallbackPrice)
        internal
        pure
        returns (int24 currentTick)
    {
        if (hookData.length == 0) {
            return ILCalculator.sqrtPriceToTick(fallbackPrice);
        }
        return abi.decode(hookData, (int24));
    }

    /// @notice Stores a new or re-opened position and snapshots its entry state.
    function addPosition(
        address owner,
        PoolId poolId,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 currentTick,
        ProtectionProfile memory profile
    ) internal returns (bytes32 positionId) {
        positionId = _positionId(owner, poolId, tickLower, tickUpper);
        Position storage existing = positions[positionId];

        if (existing.owner != address(0) && existing.state != PositionState.EXITED) {
            revert PositionAlreadyExists(positionId);
        }

        bool isFreshPosition = existing.owner == address(0);
        PositionState initialState = _isInRange(currentTick, tickLower, tickUpper) ? PositionState.ACTIVE : PositionState.IDLE;
        uint160 entryPrice = TickMath.getSqrtPriceAtTick(currentTick);

        positions[positionId] = Position({
            owner: owner,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            entryPrice: entryPrice,
            entryTimestamp: block.timestamp,
            state: initialState
        });
        profiles[positionId] = profile;

        if (isFreshPosition) {
            poolPositions[poolId].push(positionId);
        }

        emit PositionCreated(positionId, owner, poolId, tickLower, tickUpper, entryPrice, block.timestamp);

        if (address(reserve) != address(0) && initialState == PositionState.ACTIVE) {
            uint256 exposure = ILCalculator.positionValue(entryPrice, tickLower, tickUpper, liquidity);
            reserve.recordLiability(poolId, positionId, exposure);
        }
    }

    function _deployToAave(PoolId poolId, PoolKey calldata key, bytes32 positionId, int24 currentTick) internal {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.state != PositionState.IDLE) return;
        if (address(aaveAdapter) == address(0)) {
            emit AaveDepositSkipped(positionId, "adapter not configured");
            return;
        }

        address token = currentTick < position.tickLower ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        uint256 amount = uint256(position.liquidity);
        if (!aaveAdapter.canDeposit(token, amount)) {
            emit AaveDepositSkipped(positionId, "insufficient liquidity");
            return;
        }

        uint256 aTokenAmount = aaveAdapter.deposit(token, amount);
        aaveDeposits[positionId] = AaveDeposit({
            token: token,
            aToken: token,
            originalAmount: amount,
            aTokenAmount: aTokenAmount,
            depositTimestamp: block.timestamp
        });

        emit AaveDeployed(positionId, token, amount, aTokenAmount, block.timestamp);
    }

    function _recallFromAave(PoolId poolId, PoolKey calldata, bytes32 positionId, int24 currentTick) internal {
        AaveDeposit memory deposit = aaveDeposits[positionId];
        if (deposit.originalAmount == 0) return;
        if (address(aaveAdapter) == address(0)) {
            emit AaveDepositSkipped(positionId, "adapter not configured");
            return;
        }

        uint256 tokenAmount = aaveAdapter.withdraw(deposit.token, deposit.aTokenAmount);
        if (tokenAmount == 0) {
            emit AaveDepositSkipped(positionId, "withdraw unavailable");
            return;
        }

        uint256 yieldEarned = tokenAmount > deposit.originalAmount ? tokenAmount - deposit.originalAmount : 0;
        if (yieldEarned > 0 && address(reserve) != address(0)) {
            reserve.deposit(poolId, yieldEarned);
        }

        delete aaveDeposits[positionId];
        emit AaveRecalled(positionId, deposit.token, deposit.originalAmount, yieldEarned, block.timestamp);
        currentTick;
    }
}
