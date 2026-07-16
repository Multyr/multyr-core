// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockAToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "a-bal");
        balanceOf[from] -= amount;
    }
}

