// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAavePoolLike} from "./interfaces/IAavePoolLike.sol";

/// @title NovaraAaveAdapter
/// @notice Thin Aave-like adapter used by Novara Day 3.
/// @dev This contract intentionally keeps the integration surface tiny so it can be
/// unit-tested locally. The pool interface can be pointed at a mock during tests and
/// later swapped for the official Aave pool surface.
contract NovaraAaveAdapter {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR = 365 days;

    IAavePoolLike public immutable aavePool;
    address public immutable hook;

    struct DepositState {
        address asset;
        uint256 originalAmount;
        uint256 aTokenAmount;
        uint256 depositTimestamp;
        address aToken;
    }

    /// @notice Current simulated deposit state per asset.
    mapping(address => DepositState) public deposits;

    event DepositTracked(address indexed asset, uint256 amount, uint256 aTokenAmount, uint256 timestamp);
    event WithdrawalTracked(address indexed asset, uint256 amount, uint256 yieldAmount, uint256 timestamp);

    error OnlyHook();

    constructor(address aavePool_, address hook_) {
        require(aavePool_ != address(0), "pool zero");
        require(hook_ != address(0), "hook zero");
        aavePool = IAavePoolLike(aavePool_);
        hook = hook_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /// @notice Deposits an asset into the adapter's tracked Aave position.
    /// @dev This records bookkeeping and forwards the action to the configured pool.
    function deposit(address token, uint256 amount) external onlyHook returns (uint256 aTokenAmount) {
        if (amount == 0) return 0;

        IAavePoolLike.ReserveData memory reserveData = aavePool.getReserveData(token);
        address aToken = reserveData.aTokenAddress == address(0) ? token : reserveData.aTokenAddress;

        aavePool.supply(token, amount, address(this), 0);

        deposits[aToken] = DepositState({
            asset: token,
            originalAmount: amount,
            aTokenAmount: amount,
            depositTimestamp: block.timestamp,
            aToken: aToken
        });

        emit DepositTracked(token, amount, amount, block.timestamp);
        return amount;
    }

    /// @notice Withdraws an asset from the adapter's tracked Aave position.
    /// @dev Returns the principal plus any simulated yield accrued since deposit.
    function withdraw(address token, uint256 aTokenAmount) external onlyHook returns (uint256 tokenAmount) {
        address aToken = _aTokenFor(token);
        DepositState memory state = deposits[aToken];
        if (state.originalAmount == 0 || aTokenAmount == 0) return 0;

        if (!canWithdraw(token, aTokenAmount)) return 0;

        uint256 yieldAmount = getYieldAccrued(aToken, state.originalAmount);
        tokenAmount = state.originalAmount + yieldAmount;
        aavePool.withdraw(token, aTokenAmount, address(this));

        delete deposits[aToken];
        emit WithdrawalTracked(token, tokenAmount, yieldAmount, block.timestamp);
    }

    /// @notice Returns the yield accrued since the last tracked deposit.
    function getYieldAccrued(address aToken, uint256 originalAmount) public view returns (uint256 yieldAmount) {
        DepositState memory state = deposits[aToken];
        if (state.originalAmount == 0 || originalAmount == 0) return 0;

        uint256 elapsed = block.timestamp - state.depositTimestamp;
        uint256 apyBPS = currentAPY(state.asset);
        yieldAmount = (originalAmount * apyBPS * elapsed) / (BPS * YEAR);
    }

    /// @notice Returns the current supply APY for the asset, in basis points.
    function currentAPY(address token) public view returns (uint256 apyBPS) {
        IAavePoolLike.ReserveData memory reserveData = aavePool.getReserveData(token);
        apyBPS = (uint256(reserveData.currentLiquidityRate) * BPS) / RAY;
    }

    /// @notice Returns true when the pool advertises enough liquidity for the deposit.
    function canDeposit(address token, uint256 amount) public view returns (bool) {
        if (amount == 0) return false;
        return aavePool.getReserveData(token).availableLiquidity >= amount;
    }

    /// @notice Returns true when the tracked deposit can be withdrawn.
    function canWithdraw(address token, uint256 amount) public view returns (bool) {
        if (amount == 0) return false;
        return deposits[_aTokenFor(token)].aTokenAmount >= amount;
    }

    function _aTokenFor(address token) internal view returns (address aToken) {
        IAavePoolLike.ReserveData memory reserveData = aavePool.getReserveData(token);
        aToken = reserveData.aTokenAddress == address(0) ? token : reserveData.aTokenAddress;
    }
}
