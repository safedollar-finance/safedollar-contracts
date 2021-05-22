// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IAggregatorInterface.sol";

contract BDOAggregatorProxy is IAggregatorInterface {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public operator;

    address public constant bdo = address(0x190b589cf9Fb8DDEabBFeae36a813FFb2A702454);
    address public constant busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    address public bdoBusdPool = address(0xc5b0d73A7c0E4eaF66baBf7eE16A2096447f7aD6);
    address public busdUsdOracle = address(0xcBb98864Ef56E9042e7d2efef76141f15731B82f);

    uint256 public minimumReserve = 5000000 ether;

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

    function setBdoBusdPool(address _bdoBusdPool) external onlyOperator {
        bdoBusdPool = _bdoBusdPool;
    }

    function setBusdUsdOracle(address _busdUsdOracle) external onlyOperator {
        busdUsdOracle = _busdUsdOracle;
    }

    function setMinimumReserve(uint256 _minimumReserve) external onlyOperator {
        minimumReserve = _minimumReserve;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function decimals() external override view returns (uint8) {
        return IAggregatorInterface(busdUsdOracle).decimals();
    }

    function latestAnswer() external override view returns (int256) {
        (uint256 _bdoRes, uint256 _busdRes) = getReserves(bdo, busd, bdoBusdPool);
        if (_bdoRes < minimumReserve || _busdRes < minimumReserve) return 0;
        uint256 _busdUsdRate = uint256(IAggregatorInterface(busdUsdOracle).latestAnswer());
        return int256(_busdUsdRate.mul(_busdRes).div(_bdoRes));
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
