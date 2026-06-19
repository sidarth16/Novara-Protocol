// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DeploymentRegistry
/// @notice On-chain deployment registry for Novara protocol contracts.
/// @dev The registry is intentionally tiny: it stores addresses, enforces one-time writes,
/// and gives deployment scripts a single source of truth without any JSON handoff.
contract DeploymentRegistry {
    address public owner;
    address public broadcaster;
    address public usdc;
    address public weth;
    address public hook;
    address public reserve;
    address public yieldVault;
    address public adapter;
    address public reactive;
    address public priceFeed;
    address public chainlinkForwarder;
    address public poolManager;
    address public swapRouter;
    address public modifyLiquidityRouter;

    event CoreRegistered(
        address indexed usdc,
        address indexed weth,
        address indexed hook,
        address reserve,
        address yieldVault,
        address adapter,
        address reactive,
        address priceFeed
    );

    event ProtocolRegistered(address indexed chainlinkForwarder);

    event PoolRegistered(address indexed poolManager, address indexed swapRouter, address modifyLiquidityRouter);

    error NotOwner();
    error AlreadyConfigured();
    error ZeroAddress(string field);

    constructor(address broadcaster_) {
        if (broadcaster_ == address(0)) revert ZeroAddress("broadcaster");
        owner = broadcaster_;
        broadcaster = broadcaster_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function registerCore(
        address usdc_,
        address weth_,
        address hook_,
        address reserve_,
        address yieldVault_,
        address adapter_,
        address reactive_,
        address priceFeed_
    ) external onlyOwner {
        if (usdc != address(0)) revert AlreadyConfigured();
        _requireNonZero(usdc_, "usdc");
        _requireNonZero(weth_, "weth");
        _requireNonZero(hook_, "hook");
        _requireNonZero(reserve_, "reserve");
        _requireNonZero(yieldVault_, "yieldVault");
        _requireNonZero(adapter_, "adapter");
        _requireNonZero(reactive_, "reactive");
        _requireNonZero(priceFeed_, "priceFeed");

        usdc = usdc_;
        weth = weth_;
        hook = hook_;
        reserve = reserve_;
        yieldVault = yieldVault_;
        adapter = adapter_;
        reactive = reactive_;
        priceFeed = priceFeed_;

        emit CoreRegistered(usdc_, weth_, hook_, reserve_, yieldVault_, adapter_, reactive_, priceFeed_);
    }

    function registerProtocol(address chainlinkForwarder_) external onlyOwner {
        if (chainlinkForwarder != address(0)) revert AlreadyConfigured();
        _requireNonZero(chainlinkForwarder_, "chainlinkForwarder");

        chainlinkForwarder = chainlinkForwarder_;
        emit ProtocolRegistered(chainlinkForwarder_);
    }

    function registerPool(address poolManager_, address swapRouter_, address modifyLiquidityRouter_) external onlyOwner {
        if (poolManager != address(0)) revert AlreadyConfigured();
        _requireNonZero(poolManager_, "poolManager");
        _requireNonZero(swapRouter_, "swapRouter");
        _requireNonZero(modifyLiquidityRouter_, "modifyLiquidityRouter");

        poolManager = poolManager_;
        swapRouter = swapRouter_;
        modifyLiquidityRouter = modifyLiquidityRouter_;

        emit PoolRegistered(poolManager_, swapRouter_, modifyLiquidityRouter_);
    }

    function _requireNonZero(address value, string memory field) internal pure {
        if (value == address(0)) revert ZeroAddress(field);
    }
}
