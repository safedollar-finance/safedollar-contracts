// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "../lib/Babylonian.sol";
import "../lib/FixedPoint.sol";
import "../lib/UniswapV2OracleLibrary.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IEpoch.sol";
import "../interfaces/IAggregatorInterface.sol";

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract bpTokenOracle is IEpoch {
    using FixedPoint for *;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // uniswap
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
    mapping(address => address) public chainLinkOracle;

    // epoch
    address public treasury;
    mapping(uint256 => uint256) public epochPegPrice;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "bpTokenOracle: caller is not the operator");
        _;
    }

    modifier checkEpoch {
        uint256 _epoch = epoch();
        require(epochPegPrice[_epoch] == 0 || block.timestamp >= nextEpochPoint(), "bpTokenOracle: not opened yet");
        _;
    }

    modifier notInitialized {
        require(!initialized, "bpTokenOracle: already initialized");

        _;
    }

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

    function latestAnswer(address _token) external view returns (int256) {
        return IAggregatorInterface(chainLinkOracle[_token]).latestAnswer();
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
        address _mainTokenOracle,
        address _sideTokenOracle,
        address _treasury
    ) public notInitialized {
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
        chainLinkOracle[_mainToken] = _mainTokenOracle;
        chainLinkOracle[_sideToken] = _sideTokenOracle;
        treasury = _treasury;
        operator = msg.sender;

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setTreasury(address _treasury) external onlyOperator {
        treasury = _treasury;
    }

    function setChainLinkOracle(address _token, address _priceFeed) external onlyOperator {
        chainLinkOracle[_token] = _priceFeed;
    }

    function setPriceAppreciation(uint256 _priceAppreciation) external onlyOperator {
        require(_priceAppreciation <= 1e17, "_priceAppreciation is insane"); // <= 10%
        priceAppreciation = _priceAppreciation;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /** @dev Updates 1-day EMA price from Uniswap.  */
    function update() external checkEpoch {
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

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address _token, uint256 _amountIn) public view returns (uint144 _amountOut) {
        address _token0 = token0;
        address _token1 = token1;
        int256 _price0 = IAggregatorInterface(chainLinkOracle[_token0]).latestAnswer();
        int256 _price1 = IAggregatorInterface(chainLinkOracle[_token1]).latestAnswer();
        if (priceAppreciation > 0) {
            uint256 _added = _amountIn.mul(priceAppreciation).div(1e18);
            _amountIn = _amountIn.add(_added);
        }
        if (_token == _token0) {
            _amountOut = price0Average.mul(_amountIn).decode144();
            uint256 _pegPrice = uint256(_amountOut).mul(uint256(_price1)).div(uint256(_price0));
            _amountOut = uint144(_pegPrice);
        } else {
            require(_token == _token1, "bpTokenOracle: INVALID_TOKEN");
            _amountOut = price1Average.mul(_amountIn).decode144();
            uint256 _pegPrice = uint256(_amountOut).mul(uint256(_price0)).div(uint256(_price1));
            _amountOut = uint144(_pegPrice);
        }
    }

    function twap(address _token, uint256 _amountIn) public view returns (uint144 _amountOut) {
        address _token0 = token0;
        address _token1 = token1;
        int256 _price0 = IAggregatorInterface(chainLinkOracle[_token0]).latestAnswer();
        int256 _price1 = IAggregatorInterface(chainLinkOracle[_token1]).latestAnswer();
        if (priceAppreciation > 0) {
            uint256 _added = _amountIn.mul(priceAppreciation).div(1e18);
            _amountIn = _amountIn.add(_added);
        }
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (_token == _token0) {
            _amountOut = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
            uint256 _pegPrice = uint256(_amountOut).mul(uint256(_price1)).div(uint256(_price0));
            _amountOut = uint144(_pegPrice);
        } else if (_token == _token1) {
            _amountOut = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
            uint256 _pegPrice = uint256(_amountOut).mul(uint256(_price0)).div(uint256(_price1));
            _amountOut = uint144(_pegPrice);
        }
    }
}
