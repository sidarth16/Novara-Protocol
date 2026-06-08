// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3Like} from "../interfaces/IAggregatorV3Like.sol";

contract MockPriceFeed is IAggregatorV3Like {
    int256 public price;

    constructor(int256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(int256 price_) external {
        price = price_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 1;
        answer = price;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }
}
