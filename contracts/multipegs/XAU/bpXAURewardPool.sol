// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// Note that this pool has no minter key of BpXAU (rewards).
// Instead, the governance will call BpXAU distributeReward method and send reward to this pool at the beginning.
contract bpXAURewardPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. bpXAUs to distribute per block.
        uint256 lastRewardBlock; // Last block number that bpXAUs distribution occurs.
        uint256 accBpXauPerShare; // Accumulated bpXAUs per share, times 1e18. See below.
        bool isStarted; // if lastRewardBlock has passed
    }

    IERC20 public bpxau = IERC20(0x0000000000000000000000000000000000000000);

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The block number when BpXAU mining starts.
    uint256 public startBlock;

    uint256 public constant BLOCKS_PER_DAY = 28800;

    // Day 1 to day 5: 50 bpXAU daily
    // Day 6 to day 26: 12.5 bpXAU daily
    // Day 27 to day 180: 2.5 bpXAU daily
    uint256[] public epochTotalRewards = [250 ether, 262.5 ether, 385 ether];

    // Block number when each epoch ends.
    uint[3] public epochEndBlocks;

    // Reward per block for each of 3 epochs (last item is equal to 0 - for sanity).
    uint[4] public epochBpXAUPerBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _bpXAU,
        uint256 _startBlock
    ) public {
        require(block.number < _startBlock, "late");
        if (_bpXAU != address(0)) bpxau = IERC20(_bpXAU);
        startBlock = _startBlock; // supposed to be 6401000 (Fri Apr 09 2021 02:00:00 GMT+0)
        epochEndBlocks[0] = startBlock + BLOCKS_PER_DAY * 5;
        epochBpXAUPerBlock[0] = epochTotalRewards[0].div(BLOCKS_PER_DAY * 5);

        epochEndBlocks[1] = epochEndBlocks[0] + BLOCKS_PER_DAY * 21;
        epochBpXAUPerBlock[1] = epochTotalRewards[1].div(BLOCKS_PER_DAY * 21);

        epochEndBlocks[2] = epochEndBlocks[1] + BLOCKS_PER_DAY * 154;
        epochBpXAUPerBlock[2] = epochTotalRewards[2].div(BLOCKS_PER_DAY * 154);

        epochBpXAUPerBlock[3] = 0;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "bpXAURewardPool: caller is not the operator");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkPoolDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].lpToken != _lpToken, "bpXAURewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate,
        uint256 _lastRewardBlock
    ) public onlyOperator {
        checkPoolDuplicate(_lpToken);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.number < startBlock) {
            // chef is sleeping
            if (_lastRewardBlock == 0) {
                _lastRewardBlock = startBlock;
            } else {
                if (_lastRewardBlock < startBlock) {
                    _lastRewardBlock = startBlock;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardBlock == 0 || _lastRewardBlock < block.number) {
                _lastRewardBlock = block.number;
            }
        }
        bool _isStarted =
        (_lastRewardBlock <= startBlock) ||
        (_lastRewardBlock <= block.number);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : _lastRewardBlock,
            accBpXauPerShare : 0,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's BpXAU allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _from, uint256 _to) public view returns (uint256) {
        for (uint8 epochId = 3; epochId >= 1; --epochId) {
            if (_to >= epochEndBlocks[epochId - 1]) {
                if (_from >= epochEndBlocks[epochId - 1]) return _to.sub(_from).mul(epochBpXAUPerBlock[epochId]);
                uint256 _generatedReward = _to.sub(epochEndBlocks[epochId - 1]).mul(epochBpXAUPerBlock[epochId]);
                if (epochId == 1) return _generatedReward.add(epochEndBlocks[0].sub(_from).mul(epochBpXAUPerBlock[0]));
                for (epochId = epochId - 1; epochId >= 1; --epochId) {
                    if (_from >= epochEndBlocks[epochId - 1]) return _generatedReward.add(epochEndBlocks[epochId].sub(_from).mul(epochBpXAUPerBlock[epochId]));
                    _generatedReward = _generatedReward.add(epochEndBlocks[epochId].sub(epochEndBlocks[epochId - 1]).mul(epochBpXAUPerBlock[epochId]));
                }
                return _generatedReward.add(epochEndBlocks[0].sub(_from).mul(epochBpXAUPerBlock[0]));
            }
        }
        return _to.sub(_from).mul(epochBpXAUPerBlock[0]);
    }

    // View function to see pending bpXAUs on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBpXauPerShare = pool.accBpXauPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _bpXAUReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accBpXauPerShare = accBpXauPerShare.add(_bpXAUReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accBpXauPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _bpXAUReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accBpXauPerShare = pool.accBpXauPerShare.add(_bpXAUReward.mul(1e18).div(lpSupply));
        }
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accBpXauPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeBpXAUTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBpXauPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accBpXauPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeBpXAUTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBpXauPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe transfer function, just in case if rounding error causes pool to not have enough bpXAUs.
    function safeBpXAUTransfer(address _to, uint256 _amount) internal {
        uint256 _bpxauBal = bpxau.balanceOf(address(this));
        if (_bpxauBal > 0) {
            if (_amount > _bpxauBal) {
                bpxau.safeTransfer(_to, _bpxauBal);
            } else {
                bpxau.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.number < epochEndBlocks[2] + BLOCKS_PER_DAY * 180) {
            // do not allow to drain lpToken if less than 6 months after farming ends.
            require(_token != bpxau, "!bpxau");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.lpToken, "!pool.lpToken");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
