// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";

import {AbstractReactive} from "./reactive/AbstractReactive.sol";
import {NovaraHook} from "./NovaraHook.sol";

contract NovaraReactive is AbstractReactive {
    bytes32 public constant POSITION_CREATED_TOPIC =
        keccak256("PositionCreated(bytes32,address,bytes32,int24,int24,uint160,uint256)");
    bytes32 public constant PRICE_EXITED_TOPIC = keccak256("PriceExitedRange(bytes32,bytes32,int24)");
    bytes32 public constant PRICE_ENTERED_TOPIC = keccak256("PriceEnteredRange(bytes32,bytes32,int24)");
    bytes32 public constant POSITION_EXITED_TOPIC = keccak256("PositionExited(bytes32,address,uint256)");
    bytes32 public constant CRON_TOPIC = keccak256("Cron100(uint256)");

    address public immutable novaraHook;
    uint256 public activePositionCount;
    bool public cronSubscribed;

    constructor(address novaraHook_) {
        require(novaraHook_ != address(0), "hook zero");
        novaraHook = novaraHook_;
    }

    function react(LogRecord calldata log) external override {
        if (log.topic0 == POSITION_CREATED_TOPIC) {
            _handlePositionCreated(log);
        } else if (log.topic0 == PRICE_EXITED_TOPIC) {
            _handlePriceExited(log);
        } else if (log.topic0 == PRICE_ENTERED_TOPIC) {
            _handlePriceEntered(log);
        } else if (log.topic0 == POSITION_EXITED_TOPIC) {
            _handlePositionExited(log);
        } else if (_isCron(log)) {
            _handleCron(log);
        }
    }

    function _handlePositionCreated(LogRecord calldata log) internal {
        (bytes32 positionId, PoolId poolId) = abi.decode(log.data, (bytes32, PoolId));
        positionId;
        poolId;
        activePositionCount += 1;
        cronSubscribed = true;
    }

    function _handlePriceExited(LogRecord calldata log) internal {
        (bytes32 positionId, PoolId poolId, int24 currentTick) = abi.decode(log.data, (bytes32, PoolId, int24));
        poolId;
        currentTick;
        NovaraHook(novaraHook).deployToAave(positionId);
    }

    function _handlePriceEntered(LogRecord calldata log) internal {
        (bytes32 positionId, PoolId poolId, int24 currentTick) = abi.decode(log.data, (bytes32, PoolId, int24));
        poolId;
        currentTick;
        NovaraHook(novaraHook).recallFromAave(positionId);
    }

    function _handlePositionExited(LogRecord calldata log) internal {
        (bytes32 positionId, PoolId poolId) = abi.decode(log.data, (bytes32, PoolId));
        positionId;
        poolId;
        if (activePositionCount > 0) activePositionCount -= 1;
        if (activePositionCount == 0) cronSubscribed = false;
    }

    function _handleCron(LogRecord calldata) internal {
        NovaraHook(novaraHook).logReserveHealth();
        if (activePositionCount == 0) cronSubscribed = false;
    }

    function _isCron(LogRecord calldata log) internal pure returns (bool) {
        return log.topic0 == CRON_TOPIC;
    }
}
