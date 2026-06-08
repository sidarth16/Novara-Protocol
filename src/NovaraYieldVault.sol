// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAavePoolLike} from "./interfaces/IAavePoolLike.sol";

interface IDemoMintableERC20 {
    function mint(address account, uint256 value) external;
}

/// @title NovaraYieldVault
/// @notice Deterministic Aave replacement for demo flows.
/// @dev The vault keeps the same reserve-data surface that NovaraAaveAdapter already expects,
///      but it accrues yield locally and can be driven by tests/scripts without network access.
contract NovaraYieldVault is IAavePoolLike {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR = 365 days;

    struct AssetState {
        uint256 apyBps;
        uint256 totalPrincipal;
        uint256 accruedYield;
        uint256 lastAccrualTimestamp;
        bool configured;
    }

    struct DepositRecord {
        uint256 principal;
        uint256 depositTimestamp;
    }

    address public owner;

    mapping(address => AssetState) public assetStates;
    mapping(address => mapping(address => DepositRecord)) public deposits;
    address[] private listedAssets;
    mapping(address => bool) private listed;

    event AssetConfigured(address indexed asset, uint256 apyBps);
    event YieldAccrued(address indexed asset, uint256 amount, uint256 timestamp);
    event DepositTracked(address indexed asset, address indexed onBehalfOf, uint256 amount, uint256 timestamp);
    event WithdrawalTracked(address indexed asset, address indexed to, uint256 amount, uint256 yieldAmount, uint256 timestamp);

    error OnlyOwner();
    error AssetNotConfigured();
    error NothingDeposited();

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function setAssetConfig(address asset, uint256 apyBps) external onlyOwner {
        AssetState storage state = assetStates[asset];
        state.apyBps = apyBps;
        state.configured = true;
        if (state.lastAccrualTimestamp == 0) {
            state.lastAccrualTimestamp = block.timestamp;
        }
        if (!listed[asset]) {
            listed[asset] = true;
            listedAssets.push(asset);
        }
        emit AssetConfigured(asset, apyBps);
    }

    /// @notice Convenience wrapper for demo scripts.
    function deposit(address asset, uint256 amount) external returns (uint256 shares) {
        supply(asset, amount, msg.sender, 0);
        return amount;
    }

    /// @notice Convenience wrapper for demo scripts.
    function withdraw(address asset, uint256 amount) external returns (uint256 assets) {
        return withdraw(asset, amount, msg.sender);
    }

    function currentAPY(address asset) public view returns (uint256 apyBps) {
        apyBps = assetStates[asset].apyBps;
    }

    function getYieldAccrued(address asset, uint256 originalAmount) public view returns (uint256 yieldAmount) {
        AssetState memory state = assetStates[asset];
        if (!state.configured || originalAmount == 0 || state.apyBps == 0) return 0;
        if (state.lastAccrualTimestamp == 0 || block.timestamp <= state.lastAccrualTimestamp) return 0;

        uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
        yieldAmount = (originalAmount * state.apyBps * elapsed) / (BPS * YEAR);
    }

    function accrueYield(address asset) public returns (uint256 accrued) {
        accrued = _accrueAsset(asset);
    }

    function getReservesList() external view returns (address[] memory reservesList) {
        reservesList = listedAssets;
    }

    function getReserveData(address asset) external view returns (IAavePoolLike.ReserveData memory reserveData) {
        AssetState memory state = assetStates[asset];
        if (!state.configured) revert AssetNotConfigured();

        uint128 currentLiquidityRate = uint128((state.apyBps * RAY) / BPS);
        reserveData = IAavePoolLike.ReserveData({
            configuration: IAavePoolLike.ReserveConfigurationMap({data: 0}),
            liquidityIndex: uint128(RAY),
            currentLiquidityRate: currentLiquidityRate,
            variableBorrowIndex: uint128(RAY),
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: uint40(state.lastAccrualTimestamp),
            id: 0,
            aTokenAddress: asset,
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) public {
        AssetState storage state = assetStates[asset];
        if (!state.configured) revert AssetNotConfigured();
        if (amount == 0) return;

        _accrueAsset(asset);

        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        DepositRecord storage record = deposits[asset][onBehalfOf];
        if (record.principal == 0) {
            record.depositTimestamp = block.timestamp;
        }
        record.principal += amount;
        state.totalPrincipal += amount;

        emit DepositTracked(asset, onBehalfOf, amount, block.timestamp);
    }

    function withdraw(address asset, uint256 amount, address to) public returns (uint256 withdrawn) {
        AssetState storage state = assetStates[asset];
        if (!state.configured) revert AssetNotConfigured();

        DepositRecord storage record = deposits[asset][msg.sender];
        if (record.principal == 0) revert NothingDeposited();
        if (amount == 0) return 0;

        uint256 principal = amount > record.principal ? record.principal : amount;
        uint256 accruedBefore = state.accruedYield;
        uint256 preview = _previewAccrued(asset, principal);
        if (preview > 0) {
            _accrueAsset(asset);
        }
        uint256 yieldAmount = accruedBefore + preview;
        withdrawn = principal + yieldAmount;

        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < withdrawn && asset.code.length > 0) {
            uint256 shortfall = withdrawn - balance;
            IDemoMintableERC20(asset).mint(address(this), shortfall);
        }

        IERC20(asset).transfer(to, withdrawn);

        if (state.totalPrincipal >= principal) {
            state.totalPrincipal -= principal;
        } else {
            state.totalPrincipal = 0;
        }
        state.accruedYield = 0;

        delete deposits[asset][msg.sender];

        emit WithdrawalTracked(asset, to, withdrawn, yieldAmount, block.timestamp);
    }

    function _accrueAsset(address asset) internal returns (uint256 accrued) {
        AssetState storage state = assetStates[asset];
        if (!state.configured || state.totalPrincipal == 0 || state.apyBps == 0) {
            state.lastAccrualTimestamp = block.timestamp;
            return 0;
        }

        if (state.lastAccrualTimestamp == 0 || block.timestamp <= state.lastAccrualTimestamp) {
            state.lastAccrualTimestamp = block.timestamp;
            return 0;
        }

        uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
        accrued = (state.totalPrincipal * state.apyBps * elapsed) / (BPS * YEAR);
        state.lastAccrualTimestamp = block.timestamp;
        state.accruedYield += accrued;

        if (accrued > 0) {
            IDemoMintableERC20(asset).mint(address(this), accrued);
            emit YieldAccrued(asset, accrued, block.timestamp);
        }
    }

    function _previewAccrued(address asset, uint256 principal) internal view returns (uint256 yieldAmount) {
        AssetState memory state = assetStates[asset];
        if (!state.configured || principal == 0 || state.apyBps == 0) return 0;
        if (state.lastAccrualTimestamp == 0 || block.timestamp <= state.lastAccrualTimestamp) return 0;

        uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
        yieldAmount = (principal * state.apyBps * elapsed) / (BPS * YEAR);
    }
}
