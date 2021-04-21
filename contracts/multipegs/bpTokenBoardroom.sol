// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../utils/ContractGuard.sol";
import "../utils/ShareWrapper.sol";
import "../interfaces/IbpTokenBoardroom.sol";
import "../interfaces/IBasisAsset.sol";

contract bpTokenBoardroom is IbpTokenBoardroom, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
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

    address public mainBoardroom;

    mapping(address => mapping(address => Boardseat)) public directors; // pegToken => _director => Boardseat
    mapping(address => BoardSnapshot[]) public boardHistory; // pegToken => BoardSnapshot history

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event PegTokenRewardPaid(address indexed pegToken, address indexed user, uint256 reward);
    event PegTokenRewardAdded(address indexed pegToken, address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "bpTokenBoardroom: caller is not the operator");
        _;
    }

    modifier onlyMainboardroom() {
        require(mainBoardroom == msg.sender || operator == msg.sender, "bpTokenBoardroom: caller is not the main boardroom");
        _;
    }

    modifier notInitialized {
        require(!initialized, "bpTokenBoardroom: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(address _mainBoardroom) public notInitialized {
        mainBoardroom = _mainBoardroom;
        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setMainBoardroom(address _mainBoardroom) external onlyOperator {
        mainBoardroom = _mainBoardroom;
    }

    function addPegToken(address _token) external onlyOperator {
        require(boardHistory[_token].length == 0, "bpTokenBoardroom: boardHistory exists");
        BoardSnapshot memory genesisSnapshot = BoardSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        boardHistory[_token].push(genesisSnapshot);
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex(address _token) public view returns (uint256) {
        return boardHistory[_token].length.sub(1);
    }

    function getLatestSnapshot(address _token) internal view returns (BoardSnapshot memory) {
        return boardHistory[_token][latestSnapshotIndex(_token)];
    }

    function getLastSnapshotIndexOf(address _token, address _director) public view returns (uint256) {
        return directors[_token][_director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address _token, address _director) internal view returns (BoardSnapshot memory) {
        return boardHistory[_token][getLastSnapshotIndexOf(_token, _director)];
    }

    // =========== Director getters

    function rewardPerShare(address _token) public view returns (uint256) {
        return getLatestSnapshot(_token).rewardPerShare;
    }

    function earned(address _token, address _director) public override view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot(_token).rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(_token, _director).rewardPerShare;

        return ShareWrapper(mainBoardroom).balanceOf(_director).mul(latestRPS.sub(storedRPS)).div(1e18).add(directors[_token][_director].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function updateReward(address _token, address _director) external override onlyMainboardroom {
        if (_token != address(0) && _director != address(0)) {
            Boardseat memory seat = directors[_token][_director];
            seat.rewardEarned = earned(_token, _director);
            seat.lastSnapshotIndex = latestSnapshotIndex(_token);
            directors[_token][_director] = seat;
        }
    }

    function claimReward(address _token, address _director) external override onlyMainboardroom {
        uint256 reward = directors[_token][_director].rewardEarned;
        if (reward > 0) {
            directors[_token][_director].rewardEarned = 0;
            IERC20(_token).safeTransfer(_director, reward);
            emit PegTokenRewardPaid(_token, _director, reward);
        }
    }

    function allocateSeignioragePegToken(address _token, uint256 _amount) external override onlyMainboardroom {
        require(_amount > 0, "bpTokenBoardroom: Cannot allocate 0");
        uint256 _totalSupply = ShareWrapper(mainBoardroom).totalSupply();
        require(_totalSupply > 0, "bpTokenBoardroom: Cannot allocate when totalSupply is 0");
        require(boardHistory[_token].length > 0, "bpTokenBoardroom: Cannot allocate when boardHistory is empty");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot(_token).rewardPerShare;
        uint256 nextRPS = prevRPS.add(_amount.mul(1e18).div(_totalSupply));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time : block.number,
            rewardReceived : _amount,
            rewardPerShare : nextRPS
            });
        boardHistory[_token].push(newSnapshot);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        emit PegTokenRewardAdded(_token, msg.sender, _amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(boardHistory[address(_token)].length == 0, "core");
        _token.safeTransfer(_to, _amount);
    }
}
