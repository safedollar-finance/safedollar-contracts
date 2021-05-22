// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/IBEP20.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IAggregatorInterface.sol";

contract DOGEAggregatorProxy is IAggregatorInterface {
    using SafeMath for uint256;

    address public operator;

    address public constant doge = address(0xbA2aE424d960c26247Dd6c32edC70B295c744C43);
    address public constant busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address public constant usdt = address(0x55d398326f99059fF775485246999027B3197955);

    address public dogeBusdPool = address(0x1Efcb446bFa553A2EB2fff99c9F76962be6ECAC3);
    address public dogeUsdtPool = address(0xF8E9b725e0De8a9546916861c2904b0Eb8805b96);

    address public busdUsdOracle = address(0xcBb98864Ef56E9042e7d2efef76141f15731B82f);
    address public usdtUsdOracle = address(0xB97Ad0E74fa7d920791E90258A6E2085088b4320);

    uint256 public minimumReserve = 100000 * (10**8);

    constructor() public {
        operator = msg.sender;
    }

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "!operator");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setPools(address _dogeBusdPool, address _dogeUsdtPool) external onlyOperator {
        dogeBusdPool = _dogeBusdPool;
        dogeUsdtPool = _dogeUsdtPool;
    }

    function setOracles(address _busdUsdOracle, address _usdtUsdOracle) external onlyOperator {
        busdUsdOracle = _busdUsdOracle;
        usdtUsdOracle = _usdtUsdOracle;
    }

    function setMinimumReserve(uint256 _minimumReserve) external onlyOperator {
        minimumReserve = _minimumReserve;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function decimals() external override view returns (uint8) {
        uint8 _busdDecimal = IAggregatorInterface(busdUsdOracle).decimals();
        uint8 _usdtDecimal = IAggregatorInterface(usdtUsdOracle).decimals();
        return (_busdDecimal == _usdtDecimal) ? _busdDecimal : uint8(0);
    }

    function latestAnswer() external override view returns (int256) {
        (uint256 _dogeBusdRes, uint256 _busdRes) = getReserves(doge, busd, dogeBusdPool);
        (uint256 _dogeUsdtRes, uint256 _usdtRes) = getReserves(doge, usdt, dogeUsdtPool);
        uint256 _dogeDecimals = 10 ** uint256(IBEP20(doge).decimals());
        uint256 _busdUsdRate = uint256(IAggregatorInterface(busdUsdOracle).latestAnswer());
        uint256 _usdtUsdRate = uint256(IAggregatorInterface(usdtUsdOracle).latestAnswer());
        if (_dogeBusdRes < minimumReserve) {
            if (_busdRes < minimumReserve) return 0;
            return int256(_usdtUsdRate.mul(_usdtRes).mul(_dogeDecimals).div(_dogeUsdtRes).div(10 ** uint256(IBEP20(usdt).decimals())));
        }
        if (_dogeUsdtRes < minimumReserve) {
            return int256(_busdUsdRate.mul(_busdRes).mul(_dogeDecimals).div(_dogeBusdRes).div(10 ** uint256(IBEP20(busd).decimals())));
        }
        uint256 _dogeBusdRate = _busdUsdRate.mul(_busdRes).mul(_dogeDecimals).div(_dogeBusdRes).div(10 ** uint256(IBEP20(busd).decimals()));
        uint256 _dogeUsdtRate = _usdtUsdRate.mul(_usdtRes).mul(_dogeDecimals).div(_dogeUsdtRes).div(10 ** uint256(IBEP20(usdt).decimals()));
        return int256(_dogeBusdRate.mul(_dogeBusdRes).add(_dogeUsdtRate.mul(_dogeUsdtRes)).div(_dogeBusdRes.add(_dogeUsdtRes))); // (_dogeBusdRate * _dogeBusdRes + _dogeUsdtRate * _dogeUsdtRes) / (_dogeBusdRes + _dogeUsdtRes)
    }

    /* ========== LIBRARIES ========== */

    function getReserves(address tokenA, address tokenB, address pair) public view returns (uint256 _reserveA, uint256 _reserveB) {
        address _token0 = IUniswapV2Pair(pair).token0();
        address _token1 = IUniswapV2Pair(pair).token1();
        (uint112 _reserve0, uint112 _reserve1, ) = IUniswapV2Pair(pair).getReserves();
        if (_token0 == tokenA) {
            if (_token1 == tokenB) {
                _reserveA = uint256(_reserve0);
                _reserveB = uint256(_reserve1);
            }
        } else if (_token0 == tokenB) {
            if (_token1 == tokenA) {
                _reserveA = uint256(_reserve1);
                _reserveB = uint256(_reserve0);
            }
        }
    }

    function getRatio(address tokenA, address tokenB, address pair) public view returns (uint256 _ratioAoB) {
        (uint256 _reserveA, uint256 _reserveB) = getReserves(tokenA, tokenB, pair);
        if (_reserveA > 0 && _reserveB > 0) {
            _ratioAoB = _reserveA.mul(1e18).div(_reserveB);
        }
    }

    /* ========== EMERGENCY ========== */

    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data) public onlyOperator returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, string("CommunityFund::executeTransaction: Transaction execution reverted."));

        emit ExecuteTransaction(target, value, signature, data);

        return returnData;
    }

    receive() external payable {}
}
