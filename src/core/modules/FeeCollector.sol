// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { IQueueModule } from "../../interfaces/IQueueModule.sol";

interface IERC4626Minimal {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}

contract FeeCollector is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Governance
    address public immutable governor; // timelock/multisig executor

    // Sinks
    address public treasury; // protocol treasury
    address public foundationOpsSafe; // ops multisig
    address public safetyReserveVault; // safety reserve vault (1-3% of fees)

    // Split (bps)
    uint16 public treasuryBps; // e.g., 7000 = 70% to treasury
    uint16 public safetyReserveBps; // e.g., 100 = 1%, 300 = 3%
    uint16 public immutable OPS_MAX_BPS; // cap for ops share (e.g., 3000)

    // Vault fee tracking (provenance)
    mapping(address => uint256) public vaultFeeAccumulated; // vault => total fees from that vault

    // Share token handling
    enum ShareMode {
        SPLIT_SHARES,
        HOLD_TO_TREASURY,
        AUTO_HARVEST
    }

    struct ShareConfig {
        bool isSet;
        ShareMode mode;
        address underlying;
    }
    mapping(address => ShareConfig) public shareConfigs; // shareToken => config

    // Distribution thresholds and allowlist
    mapping(address => uint256) public minDistribution; // token => min amount
    mapping(address => bool) public allowedToken; // token => allowed
    bool public allowlistEnabled;

    /// @notice Tracks shares queued during AUTO_HARVEST fallback (epoch cap exhausted)
    /// @dev When requestClaim(true) falls back to queue, shares leave FeeCollector balance
    ///      but underlying is not yet delivered. Call harvestQueued() after settlement.
    mapping(address => uint256) public pendingHarvestShares; // shareToken => shares queued

    // Events
    event Distributed(
        address indexed token,
        uint256 total,
        uint256 toTreasury,
        uint256 toOps,
        uint256 toSafetyReserve
    );
    event ParamsUpdated(
        address indexed treasury,
        address indexed ops,
        address indexed safetyReserve,
        uint16 treasuryBps,
        uint16 safetyReserveBps
    );
    event MinUpdated(address indexed token, uint256 minAmount);
    event AllowedTokenUpdated(address indexed token, bool allowed);
    event AllowlistToggled(bool enabled);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event ShareConfigUpdated(
        address indexed shareToken, ShareMode mode, address indexed underlying
    );
    event Harvested(
        address indexed shareToken, address indexed underlying, uint256 sharesIn, uint256 assetsOut
    );
    event HarvestQueued(address indexed token, uint256 shares);
    event HarvestSettled(
        address indexed token, address indexed underlying, uint256 sharesRedeemed, uint256 underlyingOut
    );
    event FeeSourceTracked(address indexed vault, address indexed token, uint256 amount);

    modifier onlyGov() {
        require(msg.sender == governor, "FeeCollector: not governor");
        _;
    }

    constructor(
        address _governor,
        address _treasury,
        address _ops,
        address _safetyReserve,
        uint16 _treasuryBps,
        uint16 _safetyReserveBps,
        uint16 _opsMaxBps
    ) {
        require(_governor != address(0), "FeeCollector: governor=0");
        governor = _governor;
        OPS_MAX_BPS = _opsMaxBps;
        _setParams(_treasury, _ops, _safetyReserve, _treasuryBps, _safetyReserveBps);
    }

    // --- Admin setters ---
    function _setParams(
        address _treasury,
        address _ops,
        address _safetyReserve,
        uint16 _treasuryBps,
        uint16 _safetyReserveBps
    ) internal {
        require(_treasury != address(0) && _ops != address(0), "FeeCollector: zero addr");
        require(_safetyReserve != address(0), "FeeCollector: safetyReserve=0");
        require(_safetyReserveBps <= 300, "FeeCollector: safetyReserve>3%"); // Max 3%
        require(_treasuryBps + _safetyReserveBps <= 10_000, "FeeCollector: total bps>100%");
        uint16 opsBps = uint16(10_000 - _treasuryBps - _safetyReserveBps);
        require(opsBps <= OPS_MAX_BPS, "FeeCollector: ops>cap");
        treasury = _treasury;
        foundationOpsSafe = _ops;
        safetyReserveVault = _safetyReserve;
        treasuryBps = _treasuryBps;
        safetyReserveBps = _safetyReserveBps;
        emit ParamsUpdated(_treasury, _ops, _safetyReserve, _treasuryBps, _safetyReserveBps);
    }

    function setParams(
        address _treasury,
        address _ops,
        address _safetyReserve,
        uint16 _treasuryBps,
        uint16 _safetyReserveBps
    ) external onlyGov {
        _setParams(_treasury, _ops, _safetyReserve, _treasuryBps, _safetyReserveBps);
    }

    function setMinDistribution(address token, uint256 minAmount) external onlyGov {
        minDistribution[token] = minAmount;
        emit MinUpdated(token, minAmount);
    }

    function setAllowedToken(address token, bool allowed) external onlyGov {
        allowedToken[token] = allowed;
        emit AllowedTokenUpdated(token, allowed);
    }

    function toggleAllowlist(bool enabled) external onlyGov {
        allowlistEnabled = enabled;
        emit AllowlistToggled(enabled);
    }

    function pause() external onlyGov {
        _pause();
    }

    function unpause() external onlyGov {
        _unpause();
    }

    function setShareConfig(address shareToken, ShareMode mode) external onlyGov {
        address underlying = address(0);
        if (mode == ShareMode.AUTO_HARVEST) {
            try IERC4626Minimal(shareToken).asset() returns (address a) {
                underlying = a;
            } catch { }
            require(underlying != address(0), "FeeCollector: not ERC4626");
        } else {
            // best-effort probe for telemetry
            try IERC4626Minimal(shareToken).asset() returns (address a2) {
                underlying = a2;
            } catch { }
        }
        shareConfigs[shareToken] = ShareConfig({ isSet: true, mode: mode, underlying: underlying });
        emit ShareConfigUpdated(shareToken, mode, underlying);
    }

    // --- Distribution ---
    function distribute(address token) external nonReentrant whenNotPaused {
        if (allowlistEnabled) {
            require(allowedToken[token], "FeeCollector: token not allowed");
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "FeeCollector: no balance");

        ShareConfig memory sc = shareConfigs[token];
        bool isShare = sc.isSet;
        if (!isShare) {
            // auto-detect ERC4626 via asset()
            try IERC4626Minimal(token).asset() returns (address a) {
                isShare = (a != address(0));
                sc = ShareConfig({ isSet: false, mode: ShareMode.SPLIT_SHARES, underlying: a });
            } catch { /* not ERC4626 */ }
        }

        if (isShare) {
            if (sc.mode == ShareMode.HOLD_TO_TREASURY) {
                IERC20(token).safeTransfer(treasury, bal);
                emit Distributed(token, bal, bal, 0, 0);
                return;
            }
            if (sc.mode == ShareMode.AUTO_HARVEST) {
                require(sc.underlying != address(0), "FeeCollector: no underlying");

                // Snapshot underlying balance before the call
                uint256 underBefore = IERC20(sc.underlying).balanceOf(address(this));

                // requestClaim(true) settles inline if cap+liquidity OK;
                // falls back to queue (no revert) when epoch cap is exhausted.
                IQueueModule(token).requestClaim(true, bal);

                uint256 out = IERC20(sc.underlying).balanceOf(address(this)) - underBefore;

                if (out > 0) {
                    // HAPPY PATH: instant settlement delivered underlying in this tx
                    emit Harvested(token, sc.underlying, bal, out);
                    _distributeUnderlying(sc.underlying, out);
                } else {
                    // FALLBACK: shares moved to vault queue escrow; underlying not yet delivered.
                    // Call harvestQueued(token) after vault processes the queue.
                    pendingHarvestShares[token] += bal;
                    emit HarvestQueued(token, bal);
                }
                return;
            }
            // SPLIT_SHARES default: split share tokens directly (3-way)
            uint256 toSafetyReserveShares = (bal * safetyReserveBps) / 10_000;
            uint256 toTreasuryShares = (bal * treasuryBps) / 10_000;
            uint256 toOpsShares = bal - toTreasuryShares - toSafetyReserveShares;
            IERC20(token).safeTransfer(treasury, toTreasuryShares);
            IERC20(token).safeTransfer(foundationOpsSafe, toOpsShares);
            IERC20(token).safeTransfer(safetyReserveVault, toSafetyReserveShares);
            emit Distributed(token, bal, toTreasuryShares, toOpsShares, toSafetyReserveShares);
            return;
        }

        // Standard ERC20 (3-way split)
        uint256 minAmt = minDistribution[token];
        require(bal >= minAmt, "FeeCollector: below min");
        uint256 toSafetyReserve = (bal * safetyReserveBps) / 10_000;
        uint256 toTreasury = (bal * treasuryBps) / 10_000;
        uint256 toOps = bal - toTreasury - toSafetyReserve;
        IERC20(token).safeTransfer(treasury, toTreasury);
        IERC20(token).safeTransfer(foundationOpsSafe, toOps);
        IERC20(token).safeTransfer(safetyReserveVault, toSafetyReserve);
        emit Distributed(token, bal, toTreasury, toOps, toSafetyReserve);
    }

    /// @notice Process underlying delivered by a previously-queued AUTO_HARVEST fallback claim.
    /// @dev Call after someone has settled the pending queue entry via processQueuedRedemptions().
    ///      Anyone can call — idempotent if underlying balance is 0.
    function harvestQueued(address token) external nonReentrant whenNotPaused {
        ShareConfig memory sc = shareConfigs[token];
        require(sc.isSet && sc.mode == ShareMode.AUTO_HARVEST, "FeeCollector: not AUTO_HARVEST");
        require(sc.underlying != address(0), "FeeCollector: no underlying");

        uint256 pending = pendingHarvestShares[token];
        require(pending > 0, "FeeCollector: no pending harvest");

        // Shares should be 0 (settled by vault — escrowed shares are gone)
        require(IERC20(token).balanceOf(address(this)) == 0, "FeeCollector: shares still escrowed");

        uint256 underBal = IERC20(sc.underlying).balanceOf(address(this));
        require(underBal > 0, "FeeCollector: no underlying received");

        pendingHarvestShares[token] = 0;

        emit HarvestSettled(token, sc.underlying, pending, underBal);
        _distributeUnderlying(sc.underlying, underBal);
    }

    function _distributeUnderlying(address underlying, uint256 amount) internal {
        if (allowlistEnabled) {
            require(allowedToken[underlying], "FeeCollector: underlying not allowed");
        }
        uint256 minAmt = minDistribution[underlying];
        require(amount >= minAmt, "FeeCollector: below min underlying");
        uint256 toSafetyReserve = (amount * safetyReserveBps) / 10_000;
        uint256 toTreasury = (amount * treasuryBps) / 10_000;
        uint256 toOps = amount - toTreasury - toSafetyReserve;
        IERC20(underlying).safeTransfer(treasury, toTreasury);
        IERC20(underlying).safeTransfer(foundationOpsSafe, toOps);
        IERC20(underlying).safeTransfer(safetyReserveVault, toSafetyReserve);
        emit Distributed(underlying, amount, toTreasury, toOps, toSafetyReserve);
    }

    // --- Fee source tracking ---
    /// @notice Track fee source from a specific vault
    /// @param vault The vault address that generated the fees
    /// @param amount The amount of fees generated
    /// @dev SECURITY: Only the vault itself can track its own fees
    function trackFeeSource(address vault, uint256 amount) external {
        require(vault != address(0), "FeeCollector: vault=0");
        require(msg.sender == vault, "FeeCollector: only vault can track fees"); // SECURITY: Access control
        vaultFeeAccumulated[vault] += amount;
        emit FeeSourceTracked(vault, msg.sender, amount);
    }
}

