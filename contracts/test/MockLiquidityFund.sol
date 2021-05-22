// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../interfaces/ILiquidityFund.sol";

contract MockLiquidityFund is ILiquidityFund {
    function addLiquidity(uint256 _amount) external override {
        // Do nothing
    }
}
