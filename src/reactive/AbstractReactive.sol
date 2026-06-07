// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Lightweight stand-in for the Reactive Network base contract.
/// @dev This keeps the repo self-contained for local development and tests.
abstract contract AbstractReactive {
    struct LogRecord {
        bytes32 topic0;
        bytes data;
    }

    function react(LogRecord calldata log) external virtual;
}
