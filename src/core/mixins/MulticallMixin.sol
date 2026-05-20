// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";

/**
 * @title MulticallMixin
 * @notice Adds OZ Multicall utility to batch multiple function calls in a single tx.
 */
abstract contract MulticallMixin is Multicall { }
