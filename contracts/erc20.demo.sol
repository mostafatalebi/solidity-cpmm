pragma solidity ^0.8.25;
// SPDX-License-Identifier: GPL-1.0-or-later
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// this contract is for demo and testing, it is not 
// intended to be used anywhere on production
contract DemoToken is ERC20 {

    constructor(uint _totalSupply, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        if(_totalSupply > 0){
            _mint(msg.sender, _totalSupply);
        }
    }
}