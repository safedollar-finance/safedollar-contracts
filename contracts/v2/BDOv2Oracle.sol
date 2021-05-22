// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../lib/Babylonian.sol";
import "../lib/FixedPoint.sol";
import "../lib/UniswapV2OracleLibrary.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IEpoch.sol";

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract BDOv2Oracle is IEpoch, OwnableUpgradeSafe {
    using FixedPoint for *;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // bDex
    address public token0;
    address public token1;
    IUniswapV2Pair public pair;

    // oracle
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;
    uint256 public priceAppreciation;
    address public mainToken;
    address public sideToken;

    // epoch
    address public treasury;
    mapping(uint256 => uint256) public epochPegPrice;

    /* =================== Events =================== */

    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);

    /* ========== VIEW FUNCTIONS ========== */

    function epoch() public override view returns (uint256) {
        return IEpoch(treasury).epoch();
    }

    function nextEpochPoint() public override view returns (uint256) {
        return IEpoch(treasury).nextEpochPoint();
    }

    function nextEpochLength() external override view returns (uint256) {
        return IEpoch(treasury).nextEpochLength();
    }

    function checkEpoch() public view returns (bool) {
        return epochPegPrice[epoch()] == 0 || block.timestamp >= nextEpochPoint();
    }

    function getPegPrice() external view returns (int256) {
        return consult(mainToken, 1e18);
    }

    function getPegPriceUpdated() external view returns (int256) {
        return twap(mainToken, 1e18);
    }

    function getPegTokenPrice(address _token) external override view returns (uint256) {
        if (_token == mainToken) {
            uint256 _epoch = epoch();
            if (_epoch > 0) {
                uint256 _price = epochPegPrice[_epoch.sub(1)];
                if (_price > 0) {
                    return _price;
                }
            }
        }
        return consult(_token, 1e18);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IUniswapV2Pair _pair,
        address _mainToken,
        address _sideToken,
        address _treasury
    ) public initializer {
        OwnableUpgradeSafe.__Ownable_init();

        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();
        price0CumulativeLast = pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "bpTokenOracle: NO_RESERVES"); // ensure that there's liquidity in the pair

        mainToken = _mainToken;
        sideToken = _sideToken;
        treasury = _treasury;
    }

//    function takeOwnership() external {
//        require(_owner == address(0), "has owner already");
//        _owner = msg.sender;
//    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setPriceAppreciation(uint256 _priceAppreciation) external onlyOwner {
        require(_priceAppreciation <= 1e17, "_priceAppreciation is insane"); // <= 10%
        priceAppreciation = _priceAppreciation;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /** @dev Updates 1-day EMA price from bDex.  */
    function update() external {
        if (checkEpoch()) {
            (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
            uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

            if (timeElapsed == 0) {
                // prevent divided by zero
                return;
            }

            // overflow is desired, casting never truncates
            // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
            price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
            price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

            price0CumulativeLast = price0Cumulative;
            price1CumulativeLast = price1Cumulative;
            blockTimestampLast = blockTimestamp;

            epochPegPrice[epoch()] = consult(mainToken, 1e18);
            emit Updated(price0Cumulative, price1Cumulative);
        }
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address _token, uint256 _amountIn) public view returns (uint144 _amountOut) {
        address _token0 = token0;
        address _token1 = token1;
        if (priceAppreciation > 0) {
            uint256 _added = _amountIn.mul(priceAppreciation).div(1e18);
            _amountIn = _amountIn.add(_added);
        }
        if (_token == _token0) {
            _amountOut = price0Average.mul(_amountIn).decode144();
        } else {
            require(_token == _token1, "bpTokenOracle: INVALID_TOKEN");
            _amountOut = price1Average.mul(_amountIn).decode144();
        }
    }

    function twap(address _token, uint256 _amountIn) public view returns (uint144 _amountOut) {
        address _token0 = token0;
        address _token1 = token1;
        if (priceAppreciation > 0) {
            uint256 _added = _amountIn.mul(priceAppreciation).div(1e18);
            _amountIn = _amountIn.add(_added);
        }
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (_token == _token0) {
            _amountOut = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
        } else if (_token == _token1) {
            _amountOut = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
        }
    }
}
