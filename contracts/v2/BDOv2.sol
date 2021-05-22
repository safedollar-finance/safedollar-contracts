// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../upgrade/ERC777UpgradeSafe.sol";
import "../utils/ContractGuard.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IBasisAsset.sol";
import "../interfaces/ILiquidityFund.sol";

contract BDOv2 is ERC777UpgradeSafe, ContractGuard {
    /* ========== STATE VARIABLES ========== */
    address public operator;

    address public legacyBdo = address(0x190b589cf9Fb8DDEabBFeae36a813FFb2A702454);
    address public dollarOracle;
    bool public migrationEnabled;

    mapping(address => bool) public minter;
    uint256 public cap;

    uint256 public burnRate;
    uint256 public addLiquidityRate;
    uint256 public minAmountToAddLiquidity;
    uint256 public addLiquidityAccumulated;
    address public liquidityFund; // DAO Fund
    uint256 public dollarPriceMaxBurn;
    uint256 public dollarPriceOne;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    uint256 private _totalJackpotAdded;
    uint256 private _totalLiquidityAdded;
    uint256 public jackpotRate;
    address public jackpotFund;
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcludedToFee;

    /* ========== EVENTS ========== */

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event MinterUpdate(address indexed account, bool isMinter);
    event AddLiquidity(uint256 amount);

    /* ========== Modifiers =============== */

    modifier onlyMinter() {
        require(minter[msg.sender], "!minter");
        _;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "caller is not the operator");
        _;
    }

    function isOperator() external view returns (bool) {
        return _msgSender() == operator;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(address _legacyBdo, uint256 _cap, address[] memory _defaultOperators) public initializer {
        __ERC777_init("bDollar 2.0", "BDOv2", _defaultOperators, false);
        legacyBdo = _legacyBdo;
        cap = _cap;
        migrationEnabled = true;

        burnRate = 200; // 2%
        addLiquidityRate = 10; // 0.1%
        minAmountToAddLiquidity = 1000 ether;
        addLiquidityAccumulated = 0;
        dollarPriceMaxBurn = 0.5 ether; // burn maximum if price is equal or less than $0.5
        dollarPriceOne = 0.998 ether; // $0.998

        operator = _msgSender();
        emit OperatorTransferred(address(0), operator);
    }

    function setMigrationEnabled(bool _migrationEnabled) external onlyOperator {
        migrationEnabled = _migrationEnabled;
    }

    function setMinter(address _account, bool _isMinter) external onlyOperator {
        require(_account != address(0), "zero");
        minter[_account] = _isMinter;
        emit MinterUpdate(_account, _isMinter);
    }

    function setDollarOracle(address _dollarOracle) external onlyOperator {
        dollarOracle = _dollarOracle;
    }

    function setDollarPricePeg(uint256 _dollarPriceOne) external onlyOperator {
        require(_dollarPriceOne >= 0.9 ether && _dollarPriceOne <= 1 ether, "out range"); // [$0.9, $1.0]
        dollarPriceOne = _dollarPriceOne;
        if (dollarPriceMaxBurn > _dollarPriceOne) {
            dollarPriceMaxBurn = _dollarPriceOne;
        }
    }

    function setBurnRate(uint256 _burnRate) external onlyOperator {
        require(_burnRate <= 1000, "too high"); // <= 10%
        burnRate = _burnRate;
    }

    function setAddLiquidityRate(uint256 _addLiquidityRate) external onlyOperator {
        require(_addLiquidityRate <= 1000, "too high"); // <= 10%
        addLiquidityRate = _addLiquidityRate;
    }

    function setMinAmountToAddLiquidity(uint256 _minAmountToAddLiquidity) external onlyOperator {
        minAmountToAddLiquidity = _minAmountToAddLiquidity;
    }

    function setDollarPriceMaxBurn(uint256 _dollarPriceMaxBurn) external onlyOperator {
        require(_dollarPriceMaxBurn <= dollarPriceOne, "too high"); // <= 10%
        dollarPriceMaxBurn = _dollarPriceMaxBurn;
    }

    function setLiquidityFund(address _liquidityFund) external onlyOperator {
        liquidityFund = _liquidityFund;
    }

    function setJackpotRate(uint256 _jackpotRate) external onlyOperator {
        require(_jackpotRate <= 1000, "too high"); // <= 10%
        jackpotRate = _jackpotRate;
    }

    function setJackpotFund(address _jackpotFund) external onlyOperator {
        jackpotFund = _jackpotFund;
    }

    function transferOperator(address newOperator_) external onlyOperator {
        require(newOperator_ != address(0), "zero");
        emit OperatorTransferred(operator, newOperator_);
        operator = newOperator_;
    }

    function setExcludeFromFee(address _account, bool _status) external onlyOperator {
        _isExcludedFromFee[_account] = _status;
    }

    function setExcludeToFee(address _account, bool _status) external onlyOperator {
        _isExcludedToFee[_account] = _status;
    }

    function setExcludeBothDirectionsFee(address _account, bool _status) external onlyOperator {
        _isExcludedFromFee[_account] = _status;
        _isExcludedToFee[_account] = _status;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalJackpotAdded() external view returns (uint256) {
        return _totalJackpotAdded;
    }

    function totalLiquidityAdded() external view returns (uint256) {
        return _totalLiquidityAdded;
    }

    function getDollarPrice() public view returns (uint256) {
        return uint256(IOracle(dollarOracle).consult(address(this), 1e18));
    }

    function getDollarUpdatedPrice() public view returns (uint256) {
        return uint256(IOracle(dollarOracle).twap(address(this), 1e18));
    }

    function isExcludedFromFee(address _account) external view returns (bool) {
        return _isExcludedFromFee[_account];
    }

    function isExcludedToFee(address _account) external view returns (bool) {
        return _isExcludedToFee[_account];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function migrate(uint256 _amount) external onlyOneBlock {
        require(migrationEnabled, "migration is not enabled");
        IERC20(legacyBdo).transferFrom(msg.sender, address(this), _amount);
        IBasisAsset(legacyBdo).burn(_amount);
        _mint(msg.sender, _amount, "", "");
    }

    function mint(address _recipient, uint256 _amount) public onlyMinter returns (bool) {
        uint256 balanceBefore = balanceOf(_recipient);
        _mint(_recipient, _amount, "", "");
        uint256 balanceAfter = balanceOf(_recipient);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 _amount) external onlyOneBlock {
        _burn(msg.sender, _amount, "", "");
    }

    function burnFrom(address _account, uint256 _amount) external onlyOneBlock {
        _approve(_account, _msgSender(), allowance(_account, _msgSender()).sub(_amount, "ERC20: burn amount exceeds allowance"));
        _burn(_account, _amount, "", "");
    }

    /* ========== OVERRIDE STANDARD FUNCTIONS ========== */

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        require(recipient != address(0), "BDOv2: transfer to the zero address");

        address from = _msgSender();

        _callTokensToSend(from, from, recipient, amount, "", "");

        uint256 _amountSent = _move(from, from, recipient, amount, "", "");

        _callTokensReceived(from, from, recipient, _amountSent, "", "", false);

        return true;
    }

    function transferFrom(address holder, address recipient, uint256 amount) public override returns (bool) {
        require(recipient != address(0), "BDOv2: transfer to the zero address");
        require(holder != address(0), "BDOv2: transfer from the zero address");

        address spender = _msgSender();

        _callTokensToSend(spender, holder, recipient, amount, "", "");

        uint256 _amountSent = _move(spender, holder, recipient, amount, "", "");
        _approve(holder, spender, allowance(holder, spender).sub(amount, "BDOv2: transfer amount exceeds allowance"));

        _callTokensReceived(spender, holder, recipient, _amountSent, "", "", false);

        return true;
    }

    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - minted tokens must not cause the total supply to go over the cap.
     */
    function _beforeTokenTransfer(address _operator, address _from, address _to, uint256 _amount) internal override {
        super._beforeTokenTransfer(_operator, _from, _to, _amount);
        if (_from == address(0)) {
            // When minting tokens
            require(totalSupply().add(_amount) <= cap, "cap exceeded");
        }
    }

    /**
     * @dev Send tokens
     * @param from address token holder address
     * @param to address recipient address
     * @param amount uint256 amount of tokens to transfer
     * @param userData bytes extra information provided by the token holder (if any)
     * @param operatorData bytes extra information provided by the operator (if any)
     * @param requireReceptionAck if true, contract recipients are required to implement ERC777TokensRecipient
     */
    function _send(address from, address to, uint256 amount, bytes memory userData, bytes memory operatorData, bool requireReceptionAck) internal override {
        require(from != address(0), "BDOv2: send from the zero address");
        require(to != address(0), "BDOv2: send to the zero address");

        address _operator = _msgSender();

        _callTokensToSend(_operator, from, to, amount, userData, operatorData);

        uint256 _amountSent = _move(_operator, from, to, amount, userData, operatorData);

        _callTokensReceived(_operator, from, to, _amountSent, userData, operatorData, requireReceptionAck);
    }

    function _move(address _operator, address from, address to, uint256 amount, bytes memory userData, bytes memory operatorData) internal override returns (uint256 _amountSent) {
        _beforeTokenTransfer(_operator, from, to, amount);

        uint256 _amount = amount;

        if (!_isExcludedFromFee[from] && !_isExcludedToFee[to]) {
            {
                uint256 _jackpotRate = jackpotRate;
                if (_jackpotRate > 0) {
                    uint256 _jackpotAmount = amount.mul(_jackpotRate).div(10000);
                    address _jackpotFund = jackpotFund;
                    _balances[from] = _balances[from].sub(_jackpotAmount, "BDOv2: transfer amount exceeds balance");
                    _balances[_jackpotFund] = _balances[_jackpotFund].add(_jackpotAmount);
                    _amount = _amount.sub(_jackpotAmount);
                    _totalJackpotAdded = _totalJackpotAdded.add(_jackpotAmount);
                    emit Transfer(from, _jackpotFund, _jackpotAmount);
                }
            }
            {
                uint256 _burnAmount = 0;
                uint256 _burnRate = burnRate;
                if (_burnRate > 0) {
                    uint256 _dollarPrice = getDollarUpdatedPrice();
                    if (_dollarPrice < dollarPriceOne) {
                        uint256 _dollarPriceMaxBurn = dollarPriceMaxBurn;
                        if (_dollarPrice > _dollarPriceMaxBurn) {
                            _burnRate = _burnRate.mul(dollarPriceOne.sub(_dollarPrice)).div(dollarPriceOne.sub(_dollarPriceMaxBurn));
                        }
                        _burnAmount = amount.mul(_burnRate).div(10000);
                        _amount = _amount.sub(_burnAmount);
                    }
                }
                uint256 _addLiquidityRate = addLiquidityRate;
                if (_addLiquidityRate > 0) {
                    uint256 _addLiquidityAmount = amount.mul(_addLiquidityRate).div(10000);
                    _burnAmount = _burnAmount.add(_addLiquidityAmount);
                    _amount = _amount.sub(_addLiquidityAmount);
                    addLiquidityAccumulated = addLiquidityAccumulated.add(_addLiquidityAmount);
                    uint256 _addLiquidityAccumulated = addLiquidityAccumulated;
                    if (_addLiquidityAccumulated >= minAmountToAddLiquidity) {
                        _mint(liquidityFund, _addLiquidityAccumulated, "", "");
                        _totalLiquidityAdded = _totalLiquidityAdded.add(_addLiquidityAccumulated);
                        ILiquidityFund(liquidityFund).addLiquidity(_addLiquidityAccumulated);
                        emit AddLiquidity(_addLiquidityAccumulated);
                        addLiquidityAccumulated = 0;
                    }
                }
                if (_burnAmount > 0) {
                    _burn(from, _burnAmount, "", "");
                }
            }
        }

        _balances[from] = _balances[from].sub(_amount, "BDOv2: transfer amount exceeds balance");
        _balances[to] = _balances[to].add(_amount);
        _amountSent = _amount;

        emit Sent(_operator, from, to, _amount, userData, operatorData);
        emit Transfer(from, to, _amount);
    }

    /* ========== EMERGENCY ========== */

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
