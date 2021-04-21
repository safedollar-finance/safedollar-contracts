// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ITreasury {
    function epoch() external view returns (uint256);

    function nextEpochPoint() external view returns (uint256);

    function getDollarPrice() external view returns (uint256);

    function getPegTokenPrice(address _token) external view returns (uint256);

    function getPegTokenUpdatedPrice(address _token) external view returns (uint256);

    function dollarPriceOne() external view returns (uint256);

    function isContractionPhase(address _token) external view returns (bool);

    function buyBonds(uint256 amount, uint256 targetPrice) external;

    function redeemBonds(uint256 amount, uint256 targetPrice) external;

    function redeemPegTokenCoupons(address _token, address _account, uint256 _amount) external;
}
