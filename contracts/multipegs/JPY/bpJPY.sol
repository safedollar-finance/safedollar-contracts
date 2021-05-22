// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "../../owner/Operator.sol";

contract bpJPY is ERC20Burnable, Operator {
    uint256 public constant POOL_DISTRIBUTION = 89750000 ether;
    uint256 public constant DAO_DISTRIBUTION = 8750000 ether;
    uint256 public constant MKT_DISTRIBUTION = 1500000 ether;

    bool public rewardPoolDistributed = false;

    /**
     * @notice Constructs the bpJPY ERC-20 contract.
     */
    constructor() public ERC20("bDollar-peg JPY", "bpJPY") {
        // Mints 0.1 bpJPY to contract creator for initial pool setup
        _mint(msg.sender, 0.1 ether);
    }

    /**
     * @notice Operator mints basis bpJPY to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis bpJPY to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _distributionPool, address _daoFund, address _mktFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_distributionPool != address(0) && _daoFund != address(0) && _mktFund != address(0), "address zero");
        rewardPoolDistributed = true;
        _mint(_distributionPool, POOL_DISTRIBUTION);
        _mint(_daoFund, DAO_DISTRIBUTION);
        _mint(_mktFund, MKT_DISTRIBUTION);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
