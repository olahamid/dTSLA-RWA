// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WMONAD is IERC20 {
    error WETH__InsufficientBalance(uint256 requested, uint256 available);
    error WETH__InsufficientAllowance(uint256 requested, uint256 available);
    error WETH__WithdrawalFailed();
    error WETH__YouDidntSendMoney();

    string public name = "Wrapped MONAD";
    string public symbol = "WMND";
    uint8 public decimals = 18;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address account => mapping(address spender => uint256 amount)) public allowance;

    // receive() external payable {
    //     deposit();
    // }

    // fallback() external payable {
    //     if (msg.value > 0) {
    //         deposit();
    //     }
    // }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        if (balanceOf[msg.sender] < wad) {
            revert WETH__InsufficientBalance(wad, balanceOf[msg.sender]);
        }
        balanceOf[msg.sender] -= wad;
        emit Withdrawal(msg.sender, wad);
        // msg.sender.transfer(wad);
        (bool succ,) = msg.sender.call{ value: wad }("");
        if (!succ) {
            revert WETH__WithdrawalFailed();
        }
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        if (balanceOf[src] < wad) {
            revert WETH__InsufficientBalance(wad, balanceOf[src]);
        }

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            if (allowance[src][msg.sender] < wad) {
                revert WETH__InsufficientAllowance(wad, allowance[src][msg.sender]);
            }
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }
}
