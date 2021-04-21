// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IbpTokenBoardroom {
    function earned(address _token, address _director) external view returns (uint256);

    function updateReward(address _token, address _director) external;

    function claimReward(address _token, address _director) external;

    function allocateSeignioragePegToken(address _token, uint256 _amount) external;
}
