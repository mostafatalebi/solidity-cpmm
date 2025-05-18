pragma solidity ^0.8.25;
// SPDX-License-Identifier: GPL-1.0-or-later
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// this contract is for demo and testing, it is not 
// intended to be used anywhere on production
contract DemoToken is ERC20 {

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    constructor(uint totalSupply, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        require(totalSupply > 0, "total supply cannot be zero");
        _name = name_;
        _symbol = symbol_;

        _mint(msg.sender, totalSupply);
    }
}