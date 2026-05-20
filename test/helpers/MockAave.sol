// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IAToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
}

contract MockAavePool {
    IERC20 public immutable underlying;
    IAToken public immutable aToken;

    constructor(address _underlying, address _aToken) {
        underlying = IERC20(_underlying);
        aToken = IAToken(_aToken);
    }

    // Mimics Aave V3 Pool
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(underlying), "asset");
        require(amount > 0, "amt");
        // Pull underlying from msg.sender (adapter must have approved)
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(underlying), "asset");
        require(amount > 0, "amt");
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 wd = amount > bal ? bal : amount;
        aToken.burn(msg.sender, wd);
        require(underlying.transfer(to, wd), "send");
        return wd;
    }
}

contract MockAaveDataProvider {
    address public immutable aToken;

    constructor(address _aToken) {
        aToken = _aToken;
    }

    function getReserveTokensAddresses(address)
        external
        view
        returns (address aTokenAddress, address, address)
    {
        return (aToken, address(0), address(0));
    }
}

