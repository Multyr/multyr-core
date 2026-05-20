// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockReferralBinding {
    mapping(address => address) public referrerOf;
    mapping(address => bool) public isRouter;

    function setRouter(address router, bool enabled) external {
        isRouter[router] = enabled;
    }

    function bind(address user, address referrer) external {
        require(isRouter[msg.sender], "MockReferralBinding: not router");
        if (referrerOf[user] == address(0) && referrer != address(0)) {
            referrerOf[user] = referrer;
        }
    }
}
