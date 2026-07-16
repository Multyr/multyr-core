// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title Ownable2StepMixin
 * @notice Adds safe two-step ownership transfer (announce -> accept).
 */
abstract contract Ownable2StepMixin is Ownable2Step {
    // helper to initiate two-step transfer from composed contracts without name clash
    function _beginOwnershipTransfer(address newOwner) internal {
        Ownable2Step.transferOwnership(newOwner);
    }
}
