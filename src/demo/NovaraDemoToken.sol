// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NovaraDemoToken
/// @notice Mintable ERC20 with configurable decimals for deterministic demo flows.
contract NovaraDemoToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 tokenDecimals_) ERC20(name_, symbol_) {
        _tokenDecimals = tokenDecimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
