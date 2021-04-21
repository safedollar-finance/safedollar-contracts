// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ICouponMarket {
    function couponSupply(address _token) external view returns (uint256);

    function isContractionPhase(address _token) external view returns (bool);

    function epoch() external view returns (uint256);

    function nextEpochPoint() external view returns (uint256);

    function getPegTokenPrice(address _token) external view returns (uint256);

    function getPegTokenUpdatedPrice(address _token) external view returns (uint256);

    function issueNewCoupons(address _token, uint256 _issuedCoupon) external;

    function buyCoupons(address _token, uint256 _amount, uint256 _targetPrice) external;

    function redeemCoupons(address _token, uint256 _epoch, uint256 _amount, uint256 _targetPrice) external;
}
