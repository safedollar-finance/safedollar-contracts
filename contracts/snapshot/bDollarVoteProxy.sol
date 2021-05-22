// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IVoteProxy.sol";

contract bDollarVoteProxy {
    IVoteProxy public voteProxy;

    // governance
    address public operator;

    constructor() public {
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "DollarVoteProxy: caller is not the operator");
        _;
    }

    function name() external pure returns (string memory) {
        return "bDollar Vote Power";
    }

    function symbol() external pure returns (string memory) {
        return "sBDO VP";
    }

    function decimals() external view returns (uint8) {
        return (address(voteProxy) == address(0)) ? uint8(0) : voteProxy.decimals();
    }

    function totalSupply() external view returns (uint256) {
        return (address(voteProxy) == address(0)) ? uint256(0) : voteProxy.totalSupply();
    }

    function balanceOf(address _voter) external view returns (uint256) {
        return (address(voteProxy) == address(0)) ? uint256(0) : voteProxy.balanceOf(_voter);
    }

    function setVoteProxy(IVoteProxy _voteProxy) external onlyOperator {
        voteProxy = _voteProxy;
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
