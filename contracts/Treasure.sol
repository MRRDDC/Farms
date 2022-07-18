// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IToken.sol";

contract Treasure is Ownable {

    IToken public rewardToken;

    constructor(address _tokenAddress) {
        rewardToken = IToken(_tokenAddress);
    }

    // Safe cake transfer function, just in case if rounding error causes pool to not have enough TOKENs.
    function safeTokenTransfer(address _token, address _to, uint256 _amount) public onlyOwner {
        if (_token == address(rewardToken)) {
            rewardToken.mint(_to, _amount);
        } else {
            uint256 tokenBal = IERC20(_token).balanceOf(address(this));
            if (_amount > tokenBal) {
                IERC20(_token).transfer(_to, tokenBal);
            } else {
                IERC20(_token).transfer(_to, _amount);
            }
        }
    }
}
