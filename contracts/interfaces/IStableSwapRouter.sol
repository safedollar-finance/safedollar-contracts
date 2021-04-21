// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStableSwapRouter {
    function convert(address fromPool, address toPool, uint256 amount, uint256 minToMint, uint256 deadline) external returns (uint256);

    function addLiquidity(address pool, address basePool, uint256[] memory meta_amounts, uint256[] memory base_amounts, uint256 minToMint, uint256 deadline) external returns (uint256);
}
