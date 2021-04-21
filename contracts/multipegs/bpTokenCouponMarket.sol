// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../utils/ContractGuard.sol";
import "../interfaces/ICouponMarket.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IBasisAsset.sol";
import "../interfaces/IOracle.sol";

contract bpTokenCouponMarket is ContractGuard, ICouponMarket {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // core components
    address public treasury = address(0x15A90e6157a870CD335AF03c6df776d0B1ebf94F);

    // coupon info
    mapping(address => uint256) private _couponSupply;
    mapping(address => uint256) public couponIssued;
    mapping(address => uint256) public couponClaimed;
    mapping(address => uint256) public totalSupply;

    // coupon purchase & redeem
    uint256 public discountPercent; // when purchasing coupon
    uint256 public maxDiscountRate;
    uint256 public premiumPercent; // when redeeming coupon
    uint256 public maxPremiumRate;
    uint256 public maxRedeemableCouponPercentPerEpoch;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public purchasedCoupons; // peg_token -> user -> epoch -> purchased coupons
    mapping(address => mapping(address => uint256[])) public purchasedEpochs; // peg_token -> user -> array of purchasing epochs
    mapping(address => mapping(uint256 => uint256)) public redeemedCoupons; // peg_token -> epoch -> redeemed coupons
    mapping(address => mapping(address => uint256)) private _balances; // peg_token -> user -> coupon_balance


    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event IssueNewCoupon(address indexed pegToken, uint256 timestamp, uint256 amount);
    event BoughtCoupons(address indexed pegToken, address indexed from, uint256 epoch, uint256 pegAmount, uint256 couponAmount);
    event RedeemedCoupons(address indexed pegToken, address indexed from, uint256 epoch, uint256 redeemedEpoch, uint256 pegAmount, uint256 couponAmount);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "bpTokenCouponMarket: caller is not the operator");
        _;
    }

    modifier onlyTreasury() {
        require(treasury == msg.sender || operator == msg.sender, "bpTokenCouponMarket: caller is not a treasury nor operator");
        _;
    }

    modifier notInitialized {
        require(!initialized, "bpTokenCouponMarket: already initialized");
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function epoch() public override view returns (uint256) {
        return ITreasury(treasury).epoch();
    }

    function nextEpochPoint() public override view returns (uint256) {
        return ITreasury(treasury).nextEpochPoint();
    }

    // oracle
    function getPegTokenPrice(address _token) public override view returns (uint256) {
        return ITreasury(treasury).getPegTokenPrice(_token);
    }

    function getPegTokenUpdatedPrice(address _token) public override view returns (uint256 _pegTokenPrice) {
        return ITreasury(treasury).getPegTokenUpdatedPrice(_token);
    }

    function isContractionPhase(address _token) public override view returns (bool) {
        return ITreasury(treasury).isContractionPhase(_token);
    }

    function couponSupply(address _token) public override view returns (uint256) {
        return _couponSupply[_token];
    }

    function getCouponDiscountRate(address _token) public view returns (uint256 _rate) {
        uint256 _pegPrice = getPegTokenUpdatedPrice(_token);
        if (_pegPrice < ITreasury(treasury).dollarPriceOne()) {
            if (discountPercent == 0) {
                // no discount
                _rate = uint256(1e18);
            } else {
                uint256 _couponAmount = uint256(1e36).div(_pegPrice); // to burn 1 token
                uint256 _discountAmount = _couponAmount.sub(1e18).mul(discountPercent).div(10000);
                _rate = uint256(1e18).add(_discountAmount);
                uint256 _maxDiscountRate = maxDiscountRate;
                if (_maxDiscountRate > 0 && _rate > _maxDiscountRate) {
                    _rate = _maxDiscountRate;
                }
            }
        }
    }

    function getCouponPremiumRate(address _token) public view returns (uint256 _rate) {
        uint256 _pegPrice = getPegTokenUpdatedPrice(_token);
        if (_pegPrice >= ITreasury(treasury).getDollarPrice()) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = uint256(1e18);
            } else {
                uint256 _premiumAmount = _pegPrice.sub(1e18).mul(premiumPercent).div(10000);
                _rate = uint256(1e18).add(_premiumAmount);
                uint256 _maxPremiumRate = maxPremiumRate;
                if (_maxPremiumRate > 0 && _rate > _maxPremiumRate) {
                    _rate = _maxPremiumRate;
                }
            }
        }
    }

    function getBurnablePegTokenLeft(address _token) public view returns (uint256 _burnablePegTokenLeft) {
        uint256  _pegPrice = getPegTokenPrice(_token);
        if (_pegPrice < ITreasury(treasury).getDollarPrice()) {
            _burnablePegTokenLeft = _couponSupply[_token].mul(1e18).div(getCouponDiscountRate(_token));
        }
    }

    function getRedeemableCoupons(address _token) public view returns (uint256 _redeemableCoupons) {
        uint256  _pegPrice = getPegTokenPrice(_token);
        if (_pegPrice >= ITreasury(treasury).getDollarPrice()) {
            uint256 _epoch = epoch();
            uint256 _maxRedeemableCoupons = IERC20(_token).totalSupply().mul(maxRedeemableCouponPercentPerEpoch).div(10000);
            uint256 _redeemedCoupons = redeemedCoupons[_token][_epoch];
            _redeemableCoupons = (_maxRedeemableCoupons <= _redeemedCoupons) ? 0 : _maxRedeemableCoupons.sub(_redeemedCoupons);
        }
    }

    function getPurchasedCouponHistory(address _token, address _account) external view returns (uint256 _length, uint256[] memory _epochs, uint256[] memory _amounts) {
        uint256 _purchasedEpochLength = purchasedEpochs[_token][_account].length;
        _epochs = new uint256[](_purchasedEpochLength);
        _amounts = new uint256[](_purchasedEpochLength);
        for (uint256 _index = 0; _index < _purchasedEpochLength; _index++) {
            uint256 _ep = purchasedEpochs[_token][_account][_index];
            uint256 _amt = purchasedCoupons[_token][_account][_ep];
            if (_amt > 0) {
                _epochs[_length] = _ep;
                _amounts[_length] = _amt;
                ++_length;
            }
        }
    }

    function balanceOf(address _token, address _account) external view returns (uint256) {
        return _balances[_token][_account];
    }

    /* ========== GOVERNANCE ========== */

    function initialize(address _treasury) public notInitialized {
        treasury = _treasury;

        maxDiscountRate = 130e16; // upto 130%
        maxPremiumRate = 130e16; // upto 130%

        discountPercent = 0; // 0%
        premiumPercent = 6500; // 65%

        maxRedeemableCouponPercentPerEpoch = 300; // 3% redeemable each epoch

        initialized = true;
        operator = msg.sender;

        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMaxRedeemableCouponPercentPerEpoch(uint256 _maxRedeemableCouponPercentPerEpoch) external onlyOperator {
        require(_maxRedeemableCouponPercentPerEpoch <= 10000, "over 100%");
        maxRedeemableCouponPercentPerEpoch = _maxRedeemableCouponPercentPerEpoch;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        _token.safeTransfer(_to, _amount);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function issueNewCoupons(address _token, uint256 _issuedCoupon) external override onlyTreasury {
        _couponSupply[_token] = _couponSupply[_token].add(_issuedCoupon);
    }

    function buyCoupons(address _token, uint256 _pegAmount, uint256 _targetPrice) external override onlyOneBlock {
        require(_pegAmount > 0, "bpTokenCouponMarket: cannot purchase coupons with zero amount");

        uint256 _pegPrice = getPegTokenUpdatedPrice(_token);
        require(_pegPrice <= _targetPrice || discountPercent == 0, "bpTokenCouponMarket: peg price increased");
        require(isContractionPhase(_token), "bpTokenCouponMarket: is not in contraction");

        uint256 _burnablePegTokenLeft = getBurnablePegTokenLeft(_token);
        require(_pegAmount <= _burnablePegTokenLeft, "bpTokenCouponMarket: not enough coupon left to purchase");

        uint256 _rate = getCouponDiscountRate(_token);
        require(_rate > 0, "bpTokenCouponMarket: invalid coupon rate");

        uint256 _couponAmount = _pegAmount.mul(_rate).div(1e18);
        _couponSupply[_token] = _couponSupply[_token].sub(_couponAmount);
        couponIssued[_token] = couponIssued[_token].add(_couponAmount);

        uint256 _epoch = epoch();
        IBasisAsset(_token).burnFrom(msg.sender, _pegAmount);
        purchasedCoupons[_token][msg.sender][_epoch] = purchasedCoupons[_token][msg.sender][_epoch].add(_couponAmount);
        _balances[_token][msg.sender] = _balances[_token][msg.sender].add(_couponAmount);
        totalSupply[_token] = totalSupply[_token].add(_couponAmount);

        uint256 _purchasedEpochLength = purchasedEpochs[_token][msg.sender].length;
        if (_purchasedEpochLength == 0 || purchasedEpochs[_token][msg.sender][_purchasedEpochLength - 1] < _epoch) {
            purchasedEpochs[_token][msg.sender].push(_epoch);
        }

        emit BoughtCoupons(_token, msg.sender, _epoch, _pegAmount, purchasedCoupons[_token][msg.sender][_epoch]);
    }

    function redeemCoupons(address _token, uint256 _epoch, uint256 _couponAmount, uint256 _targetPrice) external override onlyOneBlock {
        require(_couponAmount > 0, "bpTokenCouponMarket: cannot redeem coupons with zero amount");

        uint256 _pegPrice = getPegTokenUpdatedPrice(_token);
        require(_pegPrice >= _targetPrice || premiumPercent == 0, "bpTokenCouponMarket: peg price decreased");
        require(!isContractionPhase(_token), "bpTokenCouponMarket: is in contraction");

        uint256 _redeemableCoupons = getRedeemableCoupons(_token);
        require(_couponAmount <= _redeemableCoupons, "bpTokenCouponMarket: not enough coupon available to redeem");

        uint256 _rate = getCouponPremiumRate(_token);
        require(_rate > 0, "bpTokenCouponMarket: invalid coupon rate");

        uint256 _pegAmount = _couponAmount.mul(_rate).div(1e18);
        ITreasury(treasury).redeemPegTokenCoupons(_token, msg.sender, _pegAmount);

        purchasedCoupons[_token][msg.sender][_epoch] = purchasedCoupons[_token][msg.sender][_epoch].sub(_couponAmount, "over redeem");
        _balances[_token][msg.sender] = _balances[_token][msg.sender].sub(_couponAmount);
        totalSupply[_token] = totalSupply[_token].sub(_couponAmount);
        couponClaimed[_token] = couponClaimed[_token].add(_couponAmount);

        uint256 _currentEpoch = epoch();
        redeemedCoupons[_token][_currentEpoch] = redeemedCoupons[_token][_currentEpoch].add(_couponAmount);

        emit RedeemedCoupons(_token, msg.sender, _currentEpoch, _epoch, _pegAmount, _couponAmount);
    }
}
