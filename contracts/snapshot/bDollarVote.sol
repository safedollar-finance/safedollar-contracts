// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IVoteProxy.sol";

interface IPancakePool {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IShareRewardPool {
    function userInfo(uint256 pid, address account) external view returns (uint256, uint256);
}

contract BDollarVote is IVoteProxy {
    using SafeMath for uint256;

    IShareRewardPool public shareRewardPool;
    IERC20[10] public stakePools;
    IERC20 sbdoToken;
    address public sbdo;
    uint256 public factorStake;
    uint256 public factorLP;
    uint public totalPancakePools;
    uint public totalStakePools;
    address public governance;

    struct PancakeLpPool {
        IPancakePool pool;
        uint256 pid;
    }

    PancakeLpPool[10] pancakePools;

    constructor(
        address _sbdo,
        address _shareRewardPool,
        address[] memory _stakePoolAddresses,
        uint256 _factorStake,
        uint256 _factorLP
    ) public {
        require(_stakePoolAddresses.length <= 10, "Max 10 stake pools!");
        _setStakePools(_stakePoolAddresses);
        factorLP = _factorLP;
        factorStake = _factorStake;
        sbdo = _sbdo;
        sbdoToken = IERC20(sbdo);
        shareRewardPool = IShareRewardPool(_shareRewardPool);
        governance = msg.sender;
    }

    function _setStakePools(address[] memory _stakePoolAddresses) internal {
        totalStakePools = _stakePoolAddresses.length;
        for (uint256 i = 0; i < totalStakePools; i++) {
            stakePools[i] = IERC20(_stakePoolAddresses[i]);
        }
    }

    function decimals() public pure virtual override returns (uint8) {
        return uint8(18);
    }

    function totalSupply() public view override returns (uint256) {
        uint256 totalSupplyPool = 0;
        uint256 i;
        for (i = 0; i < totalPancakePools; i++) {
            uint256 lpInPool = pancakePools[i].pool.balanceOf(address(shareRewardPool));
            totalSupplyPool = totalSupplyPool.add(lpInPool.mul(sbdoToken.balanceOf(address(pancakePools[i].pool))).div(pancakePools[i].pool.totalSupply()));
        }
        uint256 totalSupplyStake = 0;
        for (i = 0; i < totalStakePools; i++) {
            totalSupplyStake = totalSupplyStake.add(sbdoToken.balanceOf(address(stakePools[i])));
        }
        return factorLP.mul(totalSupplyPool).add(factorStake.mul(totalSupplyStake)).div(factorLP.add(factorStake));
    }

    function getSbdoAmountInPool(address _voter) public view returns (uint256) {
        uint256 stakeAmount = 0;
        for (uint256 i = 0; i < totalPancakePools; i++) {
            (uint256 _stakeAmountInPool, ) = shareRewardPool.userInfo(pancakePools[i].pid, _voter);
            stakeAmount = stakeAmount.add(_stakeAmountInPool.mul(sbdoToken.balanceOf(address(pancakePools[i].pool))).div(pancakePools[i].pool.totalSupply()));
        }
        return stakeAmount;
    }

    function getSbdoAmountInStakeContracts(address _voter) public view returns (uint256) {
        uint256 stakeAmount = 0;
        for (uint256 i = 0; i < totalStakePools; i++) {
            stakeAmount = stakeAmount.add(stakePools[i].balanceOf(_voter));
        }
        return stakeAmount;
    }

    function balanceOf(address _voter) public view override returns (uint256) {
        uint256 balanceInPool = getSbdoAmountInPool(_voter);
        uint256 balanceInStakeContract = getSbdoAmountInStakeContracts(_voter);
        return factorLP.mul(balanceInPool).add(factorStake.mul(balanceInStakeContract)).div(factorLP.add(factorStake));
    }

    function setFactorLP(uint256 _factorLP) external {
        require(msg.sender == governance, "!governance");
        require(factorStake > 0 && _factorLP > 0, "Total factors must > 0");
        factorLP = _factorLP;
    }

    function setFactorStake(uint256 _factorStake) external {
        require(msg.sender == governance, "!governance");
        require(factorLP > 0 && _factorStake > 0, "Total factors must > 0");
        factorStake = _factorStake;
    }

    function addPancakePools(address _pancakePoolAddress, uint256 pid) external {
        require(msg.sender == governance, "!governance");
        require(totalPancakePools < 10, "Max 10 pancake pools!");
        pancakePools[totalPancakePools].pool = IPancakePool(_pancakePoolAddress);
        pancakePools[totalPancakePools].pid = pid;
        totalPancakePools += 1;
    }

    function clearPancakePool() external {
        require(msg.sender == governance, "!governance");
        totalPancakePools = 0;
    }

    function setStakePools(address[] memory _stakePoolAddresses) external {
        require(msg.sender == governance, "!governance");
        _setStakePools(_stakePoolAddresses);
    }
}
