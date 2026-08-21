// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IWarmAdapter } from "../../interfaces/IWarmAdapter.sol";

// ---------- Minimal interfaces ----------
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address, address);
}

/// @title AaveV3WarmAdapter_USDC
/// @notice Adapter T+0 per Aave V3 su **USDC nativo**. Chain-agnostic: underlying/pool/data
///         provider are supplied at construction (see script/config/ChainConfig.sol).
/// @dev Controller = BufferManager. L'adapter pulla USDC dal CoreVault via transferFrom.
contract AaveV3WarmAdapter_USDC is IWarmAdapter {
    // -------- Immutable --------
    address public immutable controller; // BufferManager
    address public immutable coreVault; // CoreVault (source of funds)
    address public immutable UNDERLYING;
    IAaveV3Pool public immutable POOL;
    IERC20 public immutable USDC;
    IERC20 public immutable aToken;

    // -------- Eventi --------
    event Deposited(uint256 amountIn, uint256 sharesLikeOut);
    event Withdrawn(uint256 amountOut, address to);
    event IdleAssetSwept(uint256 amount);

    // -------- Errori --------
    error NotController();
    error ZeroAmount();
    error ZeroCoreVault();
    error ZeroUnderlying();
    error ZeroPool();
    error ZeroDataProvider();
    error ApproveFailed();
    error TransferFromFailed();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(
        address _controller,
        address _coreVault,
        address _underlying,
        address _pool,
        address _dataProvider
    ) {
        if (_coreVault == address(0)) revert ZeroCoreVault();
        if (_underlying == address(0)) revert ZeroUnderlying();
        if (_pool == address(0)) revert ZeroPool();
        if (_dataProvider == address(0)) revert ZeroDataProvider();

        controller = _controller;
        coreVault = _coreVault;
        UNDERLYING = _underlying;
        IAaveV3Pool pool = IAaveV3Pool(_pool);
        POOL = pool;
        USDC = IERC20(_underlying);

        (address aToken_,,) =
            IAaveProtocolDataProvider(_dataProvider).getReserveTokensAddresses(_underlying);
        require(aToken_ != address(0), "aToken=0");
        aToken = IERC20(aToken_);

        // Approve "infinite" al Pool
        if (!USDC.approve(address(pool), type(uint256).max)) revert ApproveFailed();
    }

    // -------- IWarmAdapter --------
    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function totalAssets() external view returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function investedAssets() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function idleAssetBalance() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function sweepIdleAssetToVault() external onlyController {
        uint256 bal = USDC.balanceOf(address(this));
        if (bal > 0) {
            require(USDC.transfer(coreVault, bal), "sweep failed");
            emit IdleAssetSwept(bal);
        }
    }

    /// @notice Deposita `amount` di USDC, pullando dal CoreVault.
    /// @dev Richiede che CoreVault abbia approvato questo adapter.
    function deposit(uint256 amount) external onlyController returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();

        // Pull USDC from CoreVault
        if (!USDC.transferFrom(coreVault, address(this), amount)) revert TransferFromFailed();

        uint256 beforeBal = aToken.balanceOf(address(this));
        POOL.supply(UNDERLYING, amount, address(this), 0);
        uint256 afterBal = aToken.balanceOf(address(this));
        received = afterBal - beforeBal; // aToken ricevuti (1:1 con underlying in ingresso)
        emit Deposited(amount, received);
    }

    /// @notice Ritira `amount` di USDC dall’Aave Pool verso `to`.
    function withdraw(uint256 amount, address to) external onlyController returns (uint256 sent) {
        if (amount == 0) revert ZeroAmount();
        sent = POOL.withdraw(UNDERLYING, amount, to);
        emit Withdrawn(sent, to);
    }
}
