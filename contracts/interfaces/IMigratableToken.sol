// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IMigratableToken {
    function migrate(uint256 _amount) external;
}
