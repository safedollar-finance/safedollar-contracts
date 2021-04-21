// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./utils/ContractGuard.sol";
import "./utils/ShareWrapper.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IbpTokenBoardroom.sol";

contract Boardroom is ShareWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    IERC20 public dollar;
    ITreasury public treasury;

    mapping(address => Boardseat) public directors;
    BoardSnapshot[] public boardHistory;

    // protocol parameters - https://github.com/bearn-defi/bdollar-smartcontracts/tree/master/docs/ProtocolParameters.md
    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    address[] public pegTokens;
    mapping(address => address) public bpTokenBoardrooms; // pegToken => its boardroom

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Boardroom: caller is not the operator");
        _;
    }

    modifier directorExists {
        require(balanceOf(msg.sender) > 0, "Boardroom: The _director does not exist");
        _;
    }

    modifier updateReward(address _director) {
        if (_director != address(0)) {
            Boardseat memory seat = directors[_director];
            seat.rewardEarned = earned(_director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[_director] = seat;
        }
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _token = pegTokens[_pti];
            address _bpTokenBoardroom = bpTokenBoardrooms[_token];
            IbpTokenBoardroom(_bpTokenBoardroom).updateReward(_token, msg.sender);
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, "Boardroom: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _dollar,
        IERC20 _share,
        ITreasury _treasury
    ) public notInitialized {
        dollar = _dollar;
        share = _share;
        treasury = _treasury;

        BoardSnapshot memory genesisSnapshot = BoardSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        boardHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 6; // Lock for 6 epochs (36h) before release withdraw
        rewardLockupEpochs = 3; // Lock for 3 epochs (18h) before release claimReward

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    function addPegToken(address _token, address _room) external onlyOperator {
        require(IERC20(_token).totalSupply() > 0, "Boardroom: invalid token");
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            require(pegTokens[_pti] != _token, "Boardroom: existing token");
        }
        pegTokens.push(_token);
        bpTokenBoardrooms[_token] = _room;
    }

    function setBpTokenBoardroom(address _token, address _room) external onlyOperator {
        bpTokenBoardrooms[_token] = _room;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address _director) public view returns (uint256) {
        return directors[_director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address _director) internal view returns (BoardSnapshot memory) {
        return boardHistory[getLastSnapshotIndexOf(_director)];
    }

    function canWithdraw(address _director) external view returns (bool) {
        return directors[_director].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address _director) external view returns (bool) {
        return directors[_director].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getDollarPrice() external view returns (uint256) {
        return treasury.getDollarPrice();
    }

    // =========== Director getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address _director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(_director).rewardPerShare;

        return balanceOf(_director).mul(latestRPS.sub(storedRPS)).div(1e18).add(directors[_director].rewardEarned);
    }

    function earnedPegToken(address _token, address _director) external view returns (uint256) {
        return IbpTokenBoardroom(bpTokenBoardrooms[_token]).earned(_token, _director);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot stake 0");
        super.stake(amount);
        directors[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock directorExists updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot withdraw 0");
        require(directors[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Boardroom: still in withdraw lockup");
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = directors[msg.sender].rewardEarned;
        if (reward > 0) {
            require(directors[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Boardroom: still in reward lockup");
            directors[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            directors[msg.sender].rewardEarned = 0;
            dollar.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _token = pegTokens[_pti];
            address _bpTokenBoardroom = bpTokenBoardrooms[_token];
            IbpTokenBoardroom(_bpTokenBoardroom).claimReward(_token, msg.sender);
        }
    }

    function allocateSeigniorage(uint256 _amount) external onlyOneBlock onlyOperator {
        require(_amount > 0, "Boardroom: Cannot allocate 0");
        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "Boardroom: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(_amount.mul(1e18).div(_totalSupply));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: _amount,
            rewardPerShare: nextRPS
        });
        boardHistory.push(newSnapshot);

        dollar.safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardAdded(msg.sender, _amount);
    }

    function allocateSeignioragePegToken(address _token, uint256 _amount) external onlyOperator {
        address _bpTokenBoardroom = bpTokenBoardrooms[_token];
        if (_bpTokenBoardroom != address(0)) {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            IERC20(_token).safeIncreaseAllowance(_bpTokenBoardroom, _amount);
            IbpTokenBoardroom(_bpTokenBoardroom).allocateSeignioragePegToken(_token, _amount);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), "dollar");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}
