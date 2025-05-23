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
error ErrIncomingTxFailed(address from, address to , uint amount);
error ErrOutgoingTxFailed(address from, address to, uint amount);
error ErrReserveIsZero();
error ErrReserveBecomesZero();
error ErrTokenLessThanExpectedAmount(uint t0, uint t1);
error ErrLpToBurnIsNotEnough();


event Swap(uint amount0, uint amount1);
event LiquidityAdded(uint amount0, uint amount1, uint outgoingLpToken);
event LiquidityRemoved(uint amount0, uint amount1, uint incomingLpToken);


contract MainAMM is ERC20 {
    bool private initialized = false;
    address owner;

    ERC20 public immutable t0;
    ERC20 public immutable t1;
    address public immutable t0Addr;
    address public immutable t1Addr;

    uint public t0t1Ratio;
    uint public t1t0Ratio;

    uint public ratioK;
    
    mapping (address => uint) public reserves;

    bool locked = false;

    modifier lock() {
        require(!locked, "Locked");
        locked = true;
        _;
        locked = false;
    }    

    
    constructor(address _t0, address _t1) ERC20("LpToken", "LPT") {      
        require(_t0 != address(0) && _t1 != address(0), ErrWrongTokenAddress());
        t0 = ERC20(_t0);
        t0Addr = _t0;
        t1 = ERC20(_t1);
        t1Addr = _t1;
        owner = msg.sender;
    }
    
    // bootstrap the contract to set initial ratio of t0 and t1
    // it can be called only once, and after that, the contract's product  
    // constant cannot be changed. 
    // It returns the ratio constant 
    function bootstrap(address _t0, address _t1, uint _amount0, uint _amount1) external lock returns (uint) {
        require(owner == msg.sender, ErrForbidden());
        require(initialized == false, ErrContractAlreadyInitialized());
        require(t0Addr == _t0 && t1Addr == _t1, ErrWrongTokenAddress());
        require(_amount0 > 0, ErrInputIsZero());
        require(_amount1 > 0, ErrInputIsZero());

        require(t0.transferFrom(msg.sender, address(this), _amount0), ErrIncomingTxFailed(msg.sender, address(this), _amount0));
        require(t1.transferFrom(msg.sender, address(this), _amount1), ErrIncomingTxFailed(msg.sender, address(this), _amount1));

        reserves[_t0] += _amount0;
        reserves[_t1] += _amount1;        

        ratioK = _calcK();
        uint _lpShare = _calcLpShare(_amount0, _amount1);
        _mint(msg.sender, _lpShare);
        _calcRatios();
        return ratioK;
    }

    function getExpectedAmount(address t, uint amount) public view returns (uint) {
        require(amount != 0, ErrInputIsZero());
        address other = _theOtherToken(t);
        require(reserves[other] > 0 && reserves[t] > 0, ErrReserveIsZero());
        return (amount * reserves[other]) / reserves[t];
    }    

    
    // swap one token for another. Given an amount of a token,
    // it calculates, after the fee reduction, the amount of
    // output value
    // the caller of this function must first approve the allowance
    // of the amount of token it sends
    function swap(address _tokenIn, uint _amountIn) external lock returns (address, uint) {
        require(_tokenIn == t0Addr || _tokenIn == t1Addr, ErrWrongTokenAddress());
        require(_amountIn > 0, ErrInputIsZero());
        require(reserves[_tokenIn] > _amountIn, ErrNotEnoughLiquidity());
        ERC20 tIn = ERC20(_tokenIn);
        require(tIn.transferFrom(msg.sender, address(this), _amountIn), ErrIncomingTxFailed(msg.sender, address(this), _amountIn));
        (uint amountInWithFee, uint amountOut) = _calcAmountOut(_tokenIn, _amountIn);
        address tokenOut = _theOtherToken(_tokenIn);
        require(reserves[tokenOut] > amountOut, ErrNotEnoughLiquidity());
        uint _t0Balance = reserves[t0Addr] + amountInWithFee;
        uint _t1Balance = reserves[t1Addr] - amountOut;
        if(_tokenIn == t1Addr) {
            _t0Balance = reserves[t0Addr] - amountOut;
            _t1Balance = reserves[t1Addr] + amountInWithFee;
        }
        ERC20 tOut = ERC20(tokenOut);
        require(tOut.transfer(msg.sender, amountOut), ErrOutgoingTxFailed(address(this), msg.sender, amountOut));
        _updateReserves(_t0Balance, _t1Balance);
        _calcRatios();
        emit Swap(_amountIn, amountOut);
        return(tokenOut, amountOut);
    }        

    // this function is core the the calcualtion of pair amount of a given token
    // it also subtracts the fee from the amountIn and the continue the calculation
    function _calcAmountOut(address tokenIn, uint amountIn) public view returns (uint amountAfterFee, uint amountOut) {
        address otherToken = _theOtherToken(tokenIn);
        amountAfterFee = amountIn * 997;
        uint numerator = amountAfterFee * reserves[otherToken];
        uint denominator = (reserves[tokenIn] * 1000) + amountAfterFee;
        amountOut = numerator / denominator;
        amountAfterFee = amountAfterFee/1000;
    }

    // given an amount for t0 and one for t1, it checks the current price ratio,
    // and forces one token's amount to retain the pricing ratio and avoid slippage. 
    // In order for this to happen, both amount MUST NOT be lower than calculated
    // expected amount of t0 and t1.
    // When conditions met, LP share of token is minted to the lp user. So in general,
    // one side of the pair will follow the pricing as given by user, and the other
    // one will follow the ratio.
    function addLiquidity(uint _amount0, uint _amount1) external lock returns (uint amount0, uint amount1, uint lpShare) {
        require(_amount0 != 0, ErrInputIsZero());
        require(_amount1 != 0, ErrInputIsZero());
        
        (amount0, amount1, lpShare) = _addLiquidity(_amount0, _amount1);
        emit LiquidityAdded(amount0, amount1, lpShare);
    }
        
    
    function _addLiquidity(uint _t0RequestedAmount, uint _t1RequestedAmount) private returns (uint amount0, uint amount1, uint lpShare) {
        require(_t0RequestedAmount != 0, ErrInputIsZero());
        require(_t1RequestedAmount != 0, ErrInputIsZero());
        require(reserves[t0Addr] > 0 && reserves[t1Addr] > 0, ErrNotEnoughLiquidity());

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

        lpShare = _calcLpShare(amount0, amount1);
        _mint(msg.sender, lpShare);
        _addToReserves(amount0, amount1);
        _calcRatios();
    }

    // based on the amount of LP recieved, it burns the LP token and
    // sends back the corresponding amount of t0 and t1 to the sender
    // LP token can be held by anyone. Withdrawl doesn't need
    // to happen by original LP receiver. This way, LP tokens
    // can be circulated around and anyone can claim back
    // t0 and t1 amounts based on the LP amount he/she is holding.
    // The caller of this, needs to first approve _lpTokenAmount of
    // allowance
    function burnLiquidity(uint _lpTokenAmount) external lock {
        require(_lpTokenAmount > 0, ErrInputIsZero());
        require(ERC20(address(this)).transferFrom(msg.sender, address(this), _lpTokenAmount), ErrIncomingTxFailed(msg.sender, address(this), _lpTokenAmount));
        uint _t0Amount = reserves[t0Addr] * _lpTokenAmount / totalSupply();
        uint _t1Amount = reserves[t1Addr] * _lpTokenAmount / totalSupply();
        require(_t0Amount > 0 && _t1Amount > 0, ErrLpToBurnIsNotEnough());

        _burn(address(this), _lpTokenAmount);
        
        require(t0.transfer(msg.sender, _t0Amount), ErrOutgoingTxFailed(address(this), msg.sender, _t0Amount));
        require(t1.transfer(msg.sender, _t1Amount), ErrOutgoingTxFailed(address(this), msg.sender, _t1Amount));

        _subtractFromReserves(_t0Amount, _t1Amount);
        _calcRatios();

        emit LiquidityRemoved(_t0Amount, _t1Amount, _lpTokenAmount);
    }

    // retursn two numbers, each representative of the expected amount of the token
    // based on the given amount of the other token as input
    function calculateExpectedAmounts(uint t0NewAmount, uint t1NewAmount) public view returns (uint expectedT1, uint expectedT0) {
        require(reserves[t0Addr] > 0, ErrReserveIsZero());
        require(reserves[t1Addr] > 0, ErrReserveIsZero());
        expectedT1 = t0NewAmount * reserves[t1Addr] / reserves[t0Addr];
        expectedT0 = t1NewAmount * reserves[t0Addr] / reserves[t1Addr];
    }

    // returns constant product of two amounts
    function _calcK() private view returns (uint) {
        return reserves[t0Addr]*reserves[t1Addr];
    }

    // the caller has to do the validation
    // it uses Solidity's default rounding down. So if 
    // the formula results in zero fee, then no fee is charged
    // it returns both the amount [minus] fee and fee
    function _calcFee(uint amount) internal pure returns (uint) {
        if(amount == 1 || amount == 0) {
            return (amount);
        }
        uint amountAfterFee = (amount * 997) / 1000;
        return (amountAfterFee);
    }

    // after each call to swap() and liquidity(), this needs to be called
    // to update latest ratios
    function _calcRatios() internal {
        t0t1Ratio = ratioK / reserves[t0Addr];
        t1t0Ratio = ratioK / reserves[t1Addr];
    }

    
    function _addToReserves(uint _amount0, uint _amount1) internal {
        reserves[t0Addr] = reserves[t0Addr] + _amount0;
        reserves[t1Addr] = reserves[t1Addr] + _amount1;
    }

    // Removes reserves and ensures it doesn't become
    // equal to zero, or below it
    function _subtractFromReserves(uint _amount0, uint _amount1) internal {
        _amount0 = reserves[t0Addr] - _amount0;
        _amount1 = reserves[t1Addr] - _amount1;
        require(_amount0 > 0 && _amount1 > 0, ErrReserveBecomesZero());
        reserves[t0Addr] = _amount0;
        reserves[t1Addr] = _amount1;
    }

    // following Uniswap's function, it calculates the assert equivalent of the base asset passed
    // to the function
    function _calcQuote(address tokenIn, uint amountIn) internal view returns (uint amountOut) {
        require(amountIn > 0, ErrInputIsZero());
        require(reserves[t0Addr] > 0 && reserves[t1Addr] > 0, ErrReserveIsZero());
        address otherToken = _theOtherToken(tokenIn);
        amountOut = amountIn * reserves[tokenIn] / reserves[otherToken];
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
    // it sets the reserves 
    function _updateReserves(uint _amount0, uint _amount1) internal  {
        require(_amount0 > 0 && _amount1 > 0, ErrInputIsZero());
        reserves[t0Addr] = _amount0;
        reserves[t1Addr] = _amount1;
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