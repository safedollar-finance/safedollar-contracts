// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";

/**
 * @title Basis Dollar Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis dollar assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public migrated = false;
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public dollar = address(0x190b589cf9Fb8DDEabBFeae36a813FFb2A702454);
    address public bond = address(0x9586b02B09bd68A7cD4aa9167a61B78F43092063);
    address public share = address(0x0d9319565be7f53CeFE84Ad201Be3f40feAE2740);

    address public boardroom;
    address public dollarOracle;

    // price
    uint256 public dollarPriceOne;
    uint256 public dollarPriceCeiling;

    uint256 public seigniorageSaved;

    // protocol parameters - https://github.com/bearn-defi/bdollar-smartcontracts/tree/master/docs/ProtocolParameters.md
    uint256 public maxSupplyExpansionPercent;
    uint256 public maxSupplyExpansionPercentInDebtPhase;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDeptRatioPercent;

    /* =================== BDOIPs (bDollar Improvement Proposals) =================== */

    // BDOIP01: 28 first epochs (1 week) with 4.5% expansion regardless of BDO price
    uint256 public bdoip01BootstrapEpochs;
    uint256 public bdoip01BootstrapSupplyExpansionPercent;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    uint256 public previousEpochDollarPrice;
    uint256 public allocateSeigniorageSalary;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra BDO during dept phase

    // BDOIP03: 10% of minted BDO goes to Community DAO Fund
    address public daoFund;
    uint256 public daoFundSharedPercent;

    // BDOIP04: 15% to DAO Fund, 3% to bVaults incentive fund, 2% to MKT
    address public bVaultsFund;
    uint256 public bVaultsFundSharedPercent;
    address public marketingFund;
    uint256 public marketingFundSharedPercent;

    // BDOIP05
    uint256 public externalRewardAmount; // buy back BDO by bVaults
    uint256 public externalRewardSharedPercent; // 100 = 1%
    uint256 public contractionBondRedeemPenaltyPercent;
    uint256 public incentiveByBondPurchaseAmount;
    uint256 public incentiveByBondPurchasePercent; // 500 = 5%
    mapping(uint256 => bool) public isContractionEpoch; // epoch => contraction (true/false)

    // Multi-Pegs
    address[] public pegTokens;
    mapping(address => address) public pegTokenOracle;
    mapping(address => address) public pegTokenFarmingPool; // to exclude balance from supply
    mapping(address => uint256) public pegTokenEpochStart;
    mapping(address => uint256) public pegTokenSupplyTarget;
    mapping(address => uint256) public pegTokenMaxSupplyExpansionPercent; // 1% = 10000
    address public couponMarket;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event RedeemedBonds(address indexed from, uint256 dollarAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 dollarAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event BVaultsFundFunded(uint256 timestamp, uint256 seigniorage);
    event MarketingFundFunded(uint256 timestamp, uint256 seigniorage);
    event ExternalRewardAdded(uint256 timestamp, uint256 dollarAmount);
    event PegTokenBoardroomFunded(address pegToken, uint256 timestamp, uint256 seigniorage);
    event PegTokenDaoFundFunded(address pegToken, uint256 timestamp, uint256 seigniorage);
    event PegTokenMarketingFundFunded(address pegToken, uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "!operator");
        _;
    }

    modifier onlyCouponMarket() {
        require(couponMarket == msg.sender, "!couponMarket");
        _;
    }

    modifier checkCondition {
        require(!migrated, "migrated");
        require(now >= startTime, "!started");

        _;
    }

    modifier checkEpoch {
        require(now >= nextEpochPoint(), "!opened");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getDollarPrice() > dollarPriceCeiling) ? 0 : IERC20(dollar).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(dollar).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isMigrated() public view returns (bool) {
        return migrated;
    }

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    function nextEpochLength() public pure returns (uint256) {
        return PERIOD;
    }

    // oracle
    function getDollarPrice() public view returns (uint256 dollarPrice) {
        try IOracle(dollarOracle).consult(dollar, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function getDollarUpdatedPrice() public view returns (uint256 _dollarPrice) {
        try IOracle(dollarOracle).twap(dollar, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function getPegTokenPrice(address _token) public view returns (uint256 _pegTokenPrice) {
        if (_token == dollar) {
            return getDollarPrice();
        }
        try IOracle(pegTokenOracle[_token]).consult(_token, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function getPegTokenUpdatedPrice(address _token) public view returns (uint256 _pegTokenPrice) {
        if (_token == dollar) {
            return getDollarUpdatedPrice();
        }
        try IOracle(pegTokenOracle[_token]).twap(_token, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableDollarLeft() public view returns (uint256 _burnableDollarLeft) {
        uint256  _dollarPrice = getDollarPrice();
        if (_dollarPrice <= dollarPriceOne) {
            uint256 _dollarSupply = IERC20(dollar).totalSupply();
            uint256 _bondMaxSupply = _dollarSupply.mul(maxDeptRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableDollar = _maxMintableBond.mul(_dollarPrice).div(1e18);
                _burnableDollarLeft = Math.min(epochSupplyContractionLeft, _maxBurnableDollar);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256  _dollarPrice = getDollarPrice();
        if (_dollarPrice > dollarPriceCeiling) {
            uint256 _totalDollar = IERC20(dollar).balanceOf(address(this));
            uint256 _rewardAmount = externalRewardAmount.add(incentiveByBondPurchaseAmount);
            if (_totalDollar > _rewardAmount) {
                uint256 _rate = getBondPremiumRate();
                if (_rate > 0) {
                    _redeemableBonds = _totalDollar.sub(_rewardAmount).mul(1e18).div(_rate);
                }
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _dollarPrice = getDollarPrice();
        if (_dollarPrice <= dollarPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = dollarPriceOne;
            } else {
                uint256 _bondAmount = dollarPriceOne.mul(1e18).div(_dollarPrice); // to burn 1 dollar
                uint256 _discountAmount = _bondAmount.sub(dollarPriceOne).mul(discountPercent).div(10000);
                _rate = dollarPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _dollarPrice = getDollarPrice();
        if (_dollarPrice > dollarPriceCeiling) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = dollarPriceOne;
            } else {
                uint256 _premiumAmount = _dollarPrice.sub(dollarPriceOne).mul(premiumPercent).div(10000);
                _rate = dollarPriceOne.add(_premiumAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondRedeemTaxRate() public view returns (uint256 _rate) {
        // BDOIP05:
        // 10% tax will be charged (to burn) for claimed BDO rewards for the first expansion epoch after contraction.
        // 5% tax will be charged (to burn) for claimed BDO rewards for the 2nd of consecutive expansion epoch after contraction.
        // No tax is charged from the 3rd expansion epoch onward
        if (epoch >= 1 && isContractionEpoch[epoch - 1]) {
            _rate = 9000;
        } else if (epoch >= 2 && isContractionEpoch[epoch - 2]) {
            _rate = 9500;
        } else {
            _rate = 10000;
        }
    }

    function getBoardroomContractionReward() external view returns (uint256) {
        uint256 _dollarBal = IERC20(dollar).balanceOf(address(this));
        uint256 _externalRewardAmount = (externalRewardAmount > _dollarBal) ? _dollarBal : externalRewardAmount;
        return _externalRewardAmount.mul(externalRewardSharedPercent).div(10000).add(incentiveByBondPurchaseAmount); // BDOIP05
    }

    function pegTokenLength() external view returns (uint256) {
        return pegTokens.length;
    }

    function getCirculatingSupply(address _token) public view returns (uint256) {
        return IERC20(_token).totalSupply().sub(IERC20(_token).balanceOf(pegTokenFarmingPool[_token]));
    }

    function getPegTokenExpansionRate(address _pegToken) public view returns (uint256 _rate) {
        uint256 _twap = getPegTokenUpdatedPrice(_pegToken);
        if (_twap > dollarPriceCeiling) {
            uint256 _percentage = _twap.sub(dollarPriceOne); // 1% = 1e16
            uint256 _mse = (_pegToken == dollar) ? maxSupplyExpansionPercent.mul(1e14) : pegTokenMaxSupplyExpansionPercent[_pegToken].mul(1e12);
            if (_percentage > _mse) {
                _percentage = _mse;
            }
            _rate = _percentage.div(1e12);
        }
    }

    function getPegTokenExpansionAmount(address _pegToken) external view returns (uint256) {
        uint256 _rate = getPegTokenExpansionRate(_pegToken);
        return getCirculatingSupply(_pegToken).mul(_rate).div(1e6);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _dollar,
        address _bond,
        address _share,
        uint256 _startTime
    ) public notInitialized {
        dollar = _dollar;
        bond = _bond;
        share = _share;
        startTime = _startTime;

        dollarPriceOne = 10**18;
        dollarPriceCeiling = dollarPriceOne.mul(101).div(100);

        maxSupplyExpansionPercent = 300; // Upto 3.0% supply for expansion
        maxSupplyExpansionPercentInDebtPhase = 450; // Upto 4.5% supply for expansion in debt phase (to pay debt faster)
        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn BDO and mint bBDO)
        maxDeptRatioPercent = 3500; // Upto 35% supply of bBDO to purchase

        // BDIP01: First 28 epochs with 4.5% expansion
        bdoip01BootstrapEpochs = 28;
        bdoip01BootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(dollar).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setDollarOracle(address _dollarOracle) external onlyOperator {
        dollarOracle = _dollarOracle;
    }

    function setDollarPricePeg(uint256 _dollarPriceOne, uint256 _dollarPriceCeiling) external onlyOperator {
        require(_dollarPriceOne >= 0.9 ether && _dollarPriceOne <= 1 ether, "out range"); // [$0.9, $1.0]
        require(_dollarPriceCeiling >= _dollarPriceOne && _dollarPriceCeiling <= _dollarPriceOne.mul(120).div(100), "out range"); // [$0.9, $1.2]
        dollarPriceOne = _dollarPriceOne;
        dollarPriceCeiling = _dollarPriceCeiling;
    }

    function setMaxSupplyExpansionContractionPercents(uint256 _maxSupplyExpansionPercent, uint256 _maxSupplyExpansionPercentInDebtPhase) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "out range"); // [0.1%, 10%]
        require(_maxSupplyExpansionPercentInDebtPhase >= 10 && _maxSupplyExpansionPercentInDebtPhase <= 1500, "out range"); // [0.1%, 15%]
        require(_maxSupplyExpansionPercent <= _maxSupplyExpansionPercentInDebtPhase, "out range");
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
        maxSupplyExpansionPercentInDebtPhase = _maxSupplyExpansionPercentInDebtPhase;
        maxSupplyContractionPercent = _maxSupplyExpansionPercent;
    }

//    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
//        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
//        bondDepletionFloorPercent = _bondDepletionFloorPercent;
//    }
//
//    function setSeigniorageExpansionFloorPercent(uint256 _seigniorageExpansionFloorPercent) external onlyOperator {
//        require(_seigniorageExpansionFloorPercent >= 2000 && _seigniorageExpansionFloorPercent <= 10000, "out of range"); // [20%, 100%]
//        seigniorageExpansionFloorPercent = _seigniorageExpansionFloorPercent;
//    }

//    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
//        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
//        maxSupplyContractionPercent = _maxSupplyContractionPercent;
//    }

//    function setMaxDeptRatioPercent(uint256 _maxDeptRatioPercent) external onlyOperator {
//        require(_maxDeptRatioPercent >= 1000 && _maxDeptRatioPercent <= 10000, "out of range"); // [10%, 100%]
//        maxDeptRatioPercent = _maxDeptRatioPercent;
//    }
//
//    function setBDOIP01(uint256 _bdoip01BootstrapEpochs, uint256 _bdoip01BootstrapSupplyExpansionPercent) external onlyOperator {
//        require(_bdoip01BootstrapEpochs <= 120, "_bdoip01BootstrapEpochs: out of range"); // <= 1 month
//        require(_bdoip01BootstrapSupplyExpansionPercent >= 100 && _bdoip01BootstrapSupplyExpansionPercent <= 1000, "_bdoip01BootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
//        bdoip01BootstrapEpochs = _bdoip01BootstrapEpochs;
//        bdoip01BootstrapSupplyExpansionPercent = _bdoip01BootstrapSupplyExpansionPercent;
//    }

    function setExtraFunds(address _daoFund, uint256 _daoFundSharedPercent,
        address _bVaultsFund, uint256 _bVaultsFundSharedPercent,
        address _marketingFund, uint256 _marketingFundSharedPercent) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_bVaultsFund != address(0), "zero");
        require(_bVaultsFundSharedPercent <= 1000, "out of range"); // <= 10%
        require(_marketingFund != address(0), "zero");
        require(_marketingFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        bVaultsFund = _bVaultsFund;
        bVaultsFundSharedPercent = _bVaultsFundSharedPercent;
        marketingFund = _marketingFund;
        marketingFundSharedPercent = _marketingFundSharedPercent;
    }

    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyOperator {
        require(_allocateSeigniorageSalary <= 100 ether, "pay too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
    }

    function setDiscountPremiumRatePercent(uint256 _discountPercent, uint256 _premiumPercent, uint256 _maxDiscountRate, uint256 _maxPremiumRate) external onlyOperator {
        require(_discountPercent <= 20000 && _premiumPercent <= 20000, "out range");
        discountPercent = _discountPercent;
        premiumPercent = _premiumPercent;
        maxDiscountRate = _maxDiscountRate;
        maxPremiumRate = _maxPremiumRate;
    }

//    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
//        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
//        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
//    }

    function setExternalRewardSharedPercent(uint256 _externalRewardSharedPercent) external onlyOperator {
        require(_externalRewardSharedPercent >= 100 && _externalRewardSharedPercent <= 5000, "out range"); // [1%, 50%]
        externalRewardSharedPercent = _externalRewardSharedPercent;
    }

    // set contractionBondRedeemPenaltyPercent = 0 to disable the redeem bond during contraction
    function setContractionBondRedeemPenaltyPercent(uint256 _contractionBondRedeemPenaltyPercent) external onlyOperator {
        require(_contractionBondRedeemPenaltyPercent <= 5000, "out range"); // <= 50%
        contractionBondRedeemPenaltyPercent = _contractionBondRedeemPenaltyPercent;
    }

    function setIncentiveByBondPurchasePercent(uint256 _incentiveByBondPurchasePercent) external onlyOperator {
        require(_incentiveByBondPurchasePercent <= 5000, "out range"); // <= 50%
        incentiveByBondPurchasePercent = _incentiveByBondPurchasePercent;
    }

    function addPegToken(address _token) external onlyOperator {
        require(IERC20(_token).totalSupply() > 0, "invalid token");
        pegTokens.push(_token);
    }

    function setPegTokenConfig(address _token, address _oracle, address _pool, uint256 _epochStart, uint256 _supplyTarget, uint256 _expansionPercent) external onlyOperator {
        pegTokenOracle[_token] = _oracle;
        pegTokenFarmingPool[_token] = _pool;
        pegTokenEpochStart[_token] = _epochStart;
        pegTokenSupplyTarget[_token] = _supplyTarget;
        pegTokenMaxSupplyExpansionPercent[_token] = _expansionPercent;
    }

    function setCouponMarket(address _couponMarket) external onlyOperator {
        couponMarket = _couponMarket;
    }

//    function migrate(address target) external onlyOperator checkOperator {
//        require(!migrated, "migrated");
//
//        // dollar
//        Operator(dollar).transferOperator(target);
//        Operator(dollar).transferOwnership(target);
//        IERC20(dollar).transfer(target, IERC20(dollar).balanceOf(address(this)));
//
//        // bond
//        Operator(bond).transferOperator(target);
//        Operator(bond).transferOwnership(target);
//        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));
//
//        // share
//        Operator(share).transferOperator(target);
//        Operator(share).transferOwnership(target);
//        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));
//
//        migrated = true;
//        emit Migration(target);
//    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateDollarPrice() internal {
        try IOracle(dollarOracle).update() {} catch {}
    }

    function _updatePegTokenPrice(address _token) internal {
        try IOracle(pegTokenOracle[_token]).update() {} catch {}
    }

    function buyBonds(uint256 _dollarAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_dollarAmount > 0, "zero amount");

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, "price moved");
        require(
            dollarPrice < dollarPriceOne, // price < $1
            "not eligible"
        );

        require(_dollarAmount <= epochSupplyContractionLeft, "not enough bond");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "invalid bond rate");

        uint256 _bondAmount = _dollarAmount.mul(_rate).div(1e18);
        uint256 dollarSupply = IERC20(dollar).totalSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(_bondAmount);
        require(newBondSupply <= dollarSupply.mul(maxDeptRatioPercent).div(10000), "over max debt ratio");
        IERC20(dollar).safeTransferFrom(msg.sender, address(this), _dollarAmount);

        if (incentiveByBondPurchasePercent > 0) {
            uint256 _incentiveByBondPurchase = _dollarAmount.mul(incentiveByBondPurchasePercent).div(10000);
            incentiveByBondPurchaseAmount = incentiveByBondPurchaseAmount.add(_incentiveByBondPurchase);
            _dollarAmount = _dollarAmount.sub(_incentiveByBondPurchase);
        }

        IBasisAsset(dollar).burn(_dollarAmount);
        IBasisAsset(bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_dollarAmount);
        _updateDollarPrice();

        emit BoughtBonds(msg.sender, _dollarAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "zero amount");

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, "price moved");

        uint256 _dollarAmount;

        if (dollarPrice < dollarPriceOne) {
            uint256 _contractionBondRedeemPenaltyPercent = contractionBondRedeemPenaltyPercent;
            require(_contractionBondRedeemPenaltyPercent > 0, "not allow");
            uint256 _penalty = _bondAmount.mul(_contractionBondRedeemPenaltyPercent).div(10000);
            _dollarAmount = _bondAmount.sub(_penalty);
            IBasisAsset(dollar).mint(address(this), _dollarAmount);
        } else {
            require(
                dollarPrice > dollarPriceCeiling, // price > $1.01
                "not eligible"
            );
            uint256 _rate = getBondPremiumRate();
            require(_rate > 0, "invalid bond rate");

            _dollarAmount = _bondAmount.mul(_rate).div(1e18);

            uint256 _bondRedeemTaxRate = getBondRedeemTaxRate();
            _dollarAmount = _dollarAmount.mul(_bondRedeemTaxRate).div(10000); // BDOIP05

            require(IERC20(dollar).balanceOf(address(this)) >= _dollarAmount.add(externalRewardAmount).add(incentiveByBondPurchaseAmount), "has no more budget");
            seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _dollarAmount));
        }

        IBasisAsset(bond).burnFrom(msg.sender, _bondAmount);
        IERC20(dollar).safeTransfer(msg.sender, _dollarAmount);

        _updateDollarPrice();

        emit RedeemedBonds(msg.sender, _dollarAmount, _bondAmount);
    }

    function _sendToBoardRoom(uint256 _amount) internal {
        IBasisAsset(dollar).mint(address(this), _amount);
        if (daoFundSharedPercent > 0) {
            uint256 _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(dollar).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
            _amount = _amount.sub(_daoFundSharedAmount);
        }
        if (bVaultsFundSharedPercent > 0) {
            uint256 _bVaultsFundSharedAmount = _amount.mul(bVaultsFundSharedPercent).div(10000);
            IERC20(dollar).transfer(bVaultsFund, _bVaultsFundSharedAmount);
            emit BVaultsFundFunded(now, _bVaultsFundSharedAmount);
            _amount = _amount.sub(_bVaultsFundSharedAmount);
        }
        if (marketingFundSharedPercent > 0) {
            uint256 _marketingSharedAmount = _amount.mul(marketingFundSharedPercent).div(10000);
            IERC20(dollar).transfer(marketingFund, _marketingSharedAmount);
            emit MarketingFundFunded(now, _marketingSharedAmount);
            _amount = _amount.sub(_marketingSharedAmount);
        }
        IERC20(dollar).safeApprove(boardroom, 0);
        IERC20(dollar).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateDollarPrice();
        previousEpochDollarPrice = getDollarPrice();
        uint256 dollarSupply = IERC20(dollar).totalSupply().sub(seigniorageSaved);
        if (epoch < bdoip01BootstrapEpochs) {// BDOIP01: 28 first epochs with 4.5% expansion
            _sendToBoardRoom(dollarSupply.mul(bdoip01BootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochDollarPrice > dollarPriceCeiling) {
                // Expansion ($BDO Price > 1$): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bond).totalSupply();
                uint256 _percentage = previousEpochDollarPrice.sub(dollarPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardRoom;
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {// saved enough to pay dept, mint as usual rate
                    uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    _savedForBoardRoom = dollarSupply.mul(_percentage).div(1e18);
                } else {// have not saved enough to pay dept, mint more
                    uint256 _mse = maxSupplyExpansionPercentInDebtPhase.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    uint256 _seigniorage = dollarSupply.mul(_percentage).div(1e18);
                    _savedForBoardRoom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardRoom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardRoom > 0) {
                    _sendToBoardRoom(_savedForBoardRoom);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(dollar).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            } else {
                // Contraction ($BDO Price <= 1$): there is some external reward to be allocated
                uint256 _externalRewardAmount = externalRewardAmount;
                uint256 _dollarBal = IERC20(dollar).balanceOf(address(this));
                if (_externalRewardAmount > _dollarBal) {
                    externalRewardAmount = _dollarBal;
                    _externalRewardAmount = _dollarBal;
                }
                if (_externalRewardAmount > 0) {
                    uint256 _externalRewardSharedPercent = externalRewardSharedPercent;
                    if (_externalRewardSharedPercent > 0) {
                        uint256 _rewardFromExternal = _externalRewardAmount.mul(_externalRewardSharedPercent).div(10000);
                        uint256 _rewardForBoardRoom = _rewardFromExternal.add(incentiveByBondPurchaseAmount);
                        if (_rewardForBoardRoom > _dollarBal) {
                            _rewardForBoardRoom = _dollarBal;
                        }
                        incentiveByBondPurchaseAmount = 0; // BDOIP05
                        IERC20(dollar).safeApprove(boardroom, 0);
                        IERC20(dollar).safeApprove(boardroom, _rewardForBoardRoom);
                        externalRewardAmount = _externalRewardAmount.sub(_rewardFromExternal);
                        IBoardroom(boardroom).allocateSeigniorage(_rewardForBoardRoom);
                        emit BoardroomFunded(now, _rewardForBoardRoom);
                    }
                }
                isContractionEpoch[epoch + 1] = true;
            }
        }
        if (allocateSeigniorageSalary > 0) {
            IBasisAsset(dollar).mint(address(msg.sender), allocateSeigniorageSalary);
        }
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _pegToken = pegTokens[_pti];
            uint256 _epochStart = pegTokenEpochStart[_pegToken];
            if (_epochStart > 0 && _epochStart <= epoch.add(1)) {
                _allocateSeignioragePegToken(_pegToken);
            }
        }
    }

    function _allocateSeignioragePegToken(address _pegToken) internal {
        _updatePegTokenPrice(_pegToken);
        uint256 _supply = getCirculatingSupply(_pegToken);
        if (_supply >= pegTokenSupplyTarget[_pegToken]) {
            pegTokenSupplyTarget[_pegToken] = pegTokenSupplyTarget[_pegToken].mul(12000).div(10000); // +20%
            pegTokenMaxSupplyExpansionPercent[_pegToken] = pegTokenMaxSupplyExpansionPercent[_pegToken].mul(9750).div(10000); // -2.5%
            if (pegTokenMaxSupplyExpansionPercent[_pegToken] < 1000) {
                pegTokenMaxSupplyExpansionPercent[_pegToken] = 1000; // min 0.1%
            }
        }
        uint256 _pegTokenTwap = getPegTokenPrice(_pegToken);
        if (_pegTokenTwap > dollarPriceCeiling) {
            uint256 _percentage = _pegTokenTwap.sub(dollarPriceOne); // 1% = 1e16
            uint256 _mse = pegTokenMaxSupplyExpansionPercent[_pegToken].mul(1e12);
            if (_percentage > _mse) {
                _percentage = _mse;
            }
            uint256 _amount = _supply.mul(_percentage).div(1e18);
            if (_amount > 0) {
                IBasisAsset(_pegToken).mint(address(this), _amount);

                uint256 _daoFundSharedAmount = _amount.mul(5750).div(10000);
                IERC20(_pegToken).transfer(daoFund, _daoFundSharedAmount);
                emit PegTokenDaoFundFunded(_pegToken, now, _daoFundSharedAmount);

                uint256 _marketingFundSharedAmount = _amount.mul(500).div(10000);
                IERC20(_pegToken).transfer(marketingFund, _marketingFundSharedAmount);
                emit PegTokenMarketingFundFunded(_pegToken, now, _marketingFundSharedAmount);

                _amount = _amount.sub(_daoFundSharedAmount.add(_marketingFundSharedAmount));
                IERC20(_pegToken).safeIncreaseAllowance(boardroom, _amount);
                IBoardroom(boardroom).allocateSeignioragePegToken(_pegToken, _amount);
                emit PegTokenDaoFundFunded(_pegToken, now, _amount);
            }
        }
    }

    function redeemPegTokenCoupons(address _pegToken, address _account, uint256 _amount) external onlyCouponMarket {
        IBasisAsset(_pegToken).mint(_account, _amount);
    }

    function notifyExternalReward(uint256 _amount) external {
        IERC20(dollar).safeTransferFrom(msg.sender, address(this), _amount);
        externalRewardAmount = externalRewardAmount.add(_amount);
        emit ExternalRewardAdded(now, _amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), "dollar");
        require(address(_token) != address(bond), "bond");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }

    /* ========== BOARDROOM CONTROLLING FUNCTIONS ========== */

    function boardroomSetConfigs(address _operator, uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        if (_operator != address(0)) IBoardroom(boardroom).setOperator(_operator);
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAddPegToken(address _token, address _room) external onlyOperator {
        IBoardroom(boardroom).addPegToken(_token, _room);
    }

//    function boardroomSetBpTokenBoardroom(address _token, address _room) external onlyOperator {
//        IBoardroom(boardroom).setBpTokenBoardroom(_token, _room);
//    }
//
//    function boardroomAllocateSeigniorage(uint256 _amount) external onlyOperator {
//        IERC20(dollar).safeIncreaseAllowance(boardroom, _amount);
//        IBoardroom(boardroom).allocateSeigniorage(_amount);
//    }
//
//    function boardroomAllocateSeignioragePegToken(address _token, uint256 _amount) external onlyOperator {
//        IERC20(_token).safeIncreaseAllowance(boardroom, _amount);
//        IBoardroom(boardroom).allocateSeignioragePegToken(_token, _amount);
//    }

    function boardroomGovernanceRecoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
