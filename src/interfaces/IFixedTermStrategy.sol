// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategy } from "./IStrategyRouter.sol";

/// @title IFixedTermStrategy
/// @notice Extension of IStrategy for fixed-maturity strategies.
/// @dev Capital flows always via StrategyRouter — Core never calls this interface directly.
///      These are view-only extensions; deposit/withdraw follow existing IStrategy patterns.
interface IFixedTermStrategy is IStrategy {

    /// @notice Returns the assets that can be withdrawn at or after maturity.
    /// @dev Returns 0 if maturity has not been reached yet or position is still locked.
    function withdrawableAtMaturity() external view returns (uint256);

    /// @notice Returns true when the strategy position has matured and liquidity is redeemable.
    /// @dev Upkeep checks this before proposing OP_FM_MARK_MATURED.
    function isMaturityReady() external view returns (bool);
}
