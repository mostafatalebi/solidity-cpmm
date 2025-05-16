// SPDX-License-Identifier: GPL-1.0-or-later
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// safe math is not needed from solidity 0.8.* onward
//import "@openzeppelin/contracts/utils/math/Math.sol";

error ErrInputIsZero();
error ErrWrongTokenAddress();
error ErrTokensTransferFailed();
error ErrNotEnoughLiquidity();
error ErrContractAlreadyInitialized();
error ErrForbidden();
error ErrTxFailed();
error ErrReserveIsZero();
error ErrTokenLessThanExpectedAmount(uint t0, uint t1);

contract MainAMM is ERC20 {
    uint LP_TOKEN_SUUPLY = 1_000_000;
    uint LP_TOKEN_LOCKED_AMOUNT_FOREVER = 1000;

    uint240 Q120 = 2**120;
    bool private initialized = false;
    address owner;

    uint public immutable feePercentage = 997; // 1000-997 = 3 / 1000 => 0.3% fee

    ERC20 public immutable t0;
    ERC20 public immutable t1;
    address public immutable t0Addr;
    address public immutable t1Addr;

    uint public t0t1Ratio;
    uint public t1t0Ratio;

    uint public ratioK;
    
    mapping (address => uint) public balances;

    mapping (address => uint) public t0LpBalance;
    mapping (address => uint) public t1LpBalance;

    uint public lastPricePnt;

    bool locked = false;

    modifier lock() {
        require(locked == false, "Locked");
        locked = true;
        _;
        locked = false;
    }    

    
    constructor(address _t0, address _t1) ERC20("MosiLpToken", "MsxLp") {      
        t0 = ERC20(_t0);
        t0Addr = _t0;
        t1 = ERC20(_t1);
        t1Addr = _t1;
        owner = msg.sender;
        _mint(address(this), LP_TOKEN_SUUPLY);
    }
    
    // bootstrap the contract to set initial ratio of t0 and t1
    // it can be called only once, and after that, the contract's product  
    // constant cannot be changed. 
    // It returns the ratio constant 
    function bootstrap(address _t0, address _t1, uint _t0Amount, uint _t1Amount) external lock returns (uint) {
        require(owner == msg.sender, ErrForbidden());
        require(initialized == false, ErrContractAlreadyInitialized());
        require(t0Addr == _t0 && t1Addr == _t1, ErrWrongTokenAddress());
        require(_t0Amount > 0, ErrInputIsZero());
        require(_t1Amount > 0, ErrInputIsZero());

        require(t0.transferFrom(msg.sender, address(this), _t0Amount), ErrTxFailed());
        require(t1.transferFrom(msg.sender, address(this), _t1Amount), ErrTxFailed());

        balances[_t0] += _t0Amount;
        balances[_t1] += _t1Amount;        

        ratioK = _calcK();

        _approve(address(this), owner, LP_TOKEN_LOCKED_AMOUNT_FOREVER);
        
        // we use burn function (not actual locking)
        // @todo we can implement locking later
        _burn(address(this), LP_TOKEN_LOCKED_AMOUNT_FOREVER);// locking forever

        uint _lpShare = _calcLpShare(_t0Amount, _t1Amount);
        _mint(msg.sender, _lpShare);
        _calcRatios();
        return ratioK;
    }

    function getExpectedAmount(address t, uint amount) public view returns (uint) {
        require(amount != 0, ErrInputIsZero());
        address other = _theOtherToken(t);
        require(balances[other] > 0 && balances[t] > 0, ErrReserveIsZero());
        return (amount * balances[other]) / balances[t];
    }    

    function swap(address tokenIn, uint amountIn) external lock returns (address, uint) {
        require(tokenIn == t0Addr || tokenIn == t1Addr, ErrWrongTokenAddress());
        require(amountIn > 0, ErrInputIsZero());
        require(balances[tokenIn]-amountIn > 0, ErrNotEnoughLiquidity());
        ERC20 tIn = ERC20(tokenIn);

        // the caller must have already approved this allowance 
        // otherwise the call fails
        require(tIn.transferFrom(msg.sender, address(this), amountIn), ErrTxFailed());
        uint newAmountIn = _calcFee(amountIn);
        (address tokenOut, uint tokenOutAmount) = _calcPair(tokenIn, newAmountIn);
        ERC20 tOut = ERC20(tokenOut);

        require(tOut.transfer(msg.sender, tokenOutAmount), ErrTxFailed());

        _calcRatios();
        return(tokenOut, tokenOutAmount);
    }    

    // given an amount for t0 and one for t1, it checks the current price ratio,
    // and forces one token's amount to retain the pricing ratio and avoid slippage. 
    // In order for this to happen, both amount MUST NOT be lower than calculated
    // expected amount of t0 and t1.
    // When conditions met, LP share of token is minted to the lp user. So in general,
    // one side of the pair will follow the pricing as given by user, and the other
    // one will follow the ratio.
    function addLiquidity(uint _t0Amount, uint _t1Amount) external lock returns (uint amount0, uint amount1, uint lpShare) {
        require(_t0Amount != 0, ErrInputIsZero());
        require(_t1Amount != 0, ErrInputIsZero());
        
        (amount0, amount1, lpShare) = _addLiquidity(_t0Amount, _t1Amount);
    }
    
    
    function _addLiquidity(uint _t0RequestedAmount, uint _t1RequestedAmount) private returns (uint amount0, uint amount1, uint lpShare) {
        require(_t0RequestedAmount != 0, ErrInputIsZero());
        require(_t1RequestedAmount != 0, ErrInputIsZero());
        require(balances[t0Addr] > 0 && balances[t1Addr] > 0, ErrNotEnoughLiquidity());

        uint expected_1 = getExpectedAmount(t0Addr, _t0RequestedAmount);
        if(expected_1 <= _t1RequestedAmount){
            amount0 = _t0RequestedAmount;
            amount1 = expected_1;
        } else {
            uint expected_0 = getExpectedAmount(t1Addr, _t1RequestedAmount);
            if(expected_0 <= _t0RequestedAmount){
                amount0 = expected_0;
                amount1 = _t1RequestedAmount;
            } else {
                revert ErrTokenLessThanExpectedAmount(_t0RequestedAmount, _t1RequestedAmount); 
            }
        } 
        
        bool r0 = t0.transferFrom(msg.sender, address(this), amount0);        
        bool r2 = t1.transferFrom(msg.sender, address(this), amount1);

        require(r0 && r2, ErrTokensTransferFailed());
        
        _addToLp(amount0, amount1);

        lpShare = _calcLpShare(amount0, amount1);
        _mint(msg.sender, lpShare);
    }

    // retursn two numbers, each representative of the expected amount of the token
    // based on the given amount of the other token as input
    function calculateExpectedAmounts(uint t0NewAmount, uint t1NewAmount) public view returns (uint expectedT1, uint expectedT0) {
        require(balances[t0Addr] > 0, ErrReserveIsZero());
        require(balances[t1Addr] > 0, ErrReserveIsZero());
        expectedT1 = t0NewAmount * balances[t1Addr] / balances[t0Addr];
        expectedT0 = t1NewAmount * balances[t0Addr] / balances[t1Addr];
    }

    // it returns the share of the LP from the pool
    // in percentage
    function _addToLp(uint _t0Amount, uint _t1Amount) private returns (uint) {
        t0LpBalance[msg.sender] += _t0Amount;
        t1LpBalance[msg.sender] += _t1Amount;

        return 0;
    }

    function subtractFromLp(uint _t0Amount, uint _t1Amount) private {
        t0LpBalance[msg.sender] -= _t0Amount;
        t1LpBalance[msg.sender] -= _t1Amount;
    }

    // returns constant product of two amounts
    function _calcK() private view returns (uint) {
        return balances[t0Addr]*balances[t1Addr];
    }

    // the caller has to do the validation
    // it uses Solidity's default rounding down. So if 
    // the formula results in zero fee, then no fee is charged
    // it returns both the amount [minus] fee and fee
    function _calcFee(uint amount) internal pure returns (uint) {
        if(amount == 1 || amount == 0) {
            return (amount);
        }
        uint amountAfterFee = (amount * feePercentage) / 1000;
        return (amountAfterFee);
    }

    function _calcCumulativePrices() internal returns (uint240, uint240) {

    }

    function fixedNumber(uint120 n) internal view returns (uint240) {
        return uint240(n * Q120);
    }

    // after each call to execute(), this needs to be called
    // to update latest ratios
    function _calcRatios() internal {
        t0t1Ratio = ratioK / balances[t0Addr];
        t1t0Ratio = ratioK / balances[t1Addr];
    }

    // following Uniswap's function, it calculates the assert equivalent of the base asset passed
    // to the function
    function _calcQuote(address tokenIn, uint amountIn) internal view returns (uint amountOut) {
        require(amountIn > 0, ErrInputIsZero());
        require(balances[t0Addr] > 0 && balances[t1Addr] > 0, ErrReserveIsZero());
        address otherToken = _theOtherToken(tokenIn);
        amountOut = amountIn * balances[tokenIn] / balances[otherToken];
    }


    // For a pair, pass a token's address and it returns the other address
    function _theOtherToken(address _t) internal view returns (address _otherToken) {
        if(_t == t0Addr) {
            _otherToken = t1Addr;
        } else if (_t == t1Addr) {
            _otherToken = t0Addr;
        } else {
            revert ErrWrongTokenAddress();
        }
    }

    // the caller has to do the validation
    // returns tokenOut address as well as the amount of tokenOut calculated
    function _calcPair(address tokenIn, uint amountIn) internal returns (address, uint) {
        address tokenOut = t1Addr;
        if(tokenIn == t1Addr) {
            tokenOut = t0Addr;
        }
        balances[tokenIn] = balances[tokenIn]+amountIn;

        uint _tOutEquivalent = ratioK / balances[tokenIn];
        uint tokenOutAmount = balances[tokenOut]-_tOutEquivalent;
        balances[tokenOut] = balances[tokenOut]-tokenOutAmount;
        return (tokenOut, tokenOutAmount);
    }

    function _calcLpShare(uint _t0, uint _t1) internal pure returns (uint) {
        return sqrt(_t0 * _t1);
    }

    // copied from Uniswap V2
    // we also use the same technique of sqr root
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}