// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// safe math is not needed from solidity 0.8.* onward
//import "@openzeppelin/contracts/utils/math/Math.sol";

error ErrInputIsZero();
error ErrWrongTokenAddress();
error ErrTokensTransferFailed();
error ErrNotEnoughLiquidity();
error ErrContractAlreadyInitialized();

contract MosiCPMM is ERC20 {
    constant uint120 Q120 = 2**120;
    bool private initialized = false;
    address owner;

    uint public immutable feePercentage = 997; // 1000-997 = 3 / 1000 => 0.3% fee

    ERC20 public immutable t0;
    ERC20 public immutable t1;
    address public immutable t0Addr;
    address public immutable t1Addr;

    uint public ratioK;
    
    mapping (address => uint) public balances;

    mapping (address => uint) public t0LpBalance;
    mapping (address => uint) public t1LpBalance;

    uint public lastPricePnt;
    

    
    constructor(address _t0, address _t1) ERC20("MosiLpToken", "MsxLp") {      
        t0 = ERC20(_t0);
        t0Addr = _t0;
        t1 = ERC20(_t1);
        t1Addr = _t1;
    }
    
    // bootstrap the contract to set initial ratio of t0 and t1
    // it can be called only once, and after that, the contract's pair ratio 
    // cannot be changed. 
    // It returns the ration contant 
    function bootstrap(address _t0, address _t1, uint _t0Amount, uint _t1Amount) external returns (uint) {
        require(initialized == false, ErrContractAlreadyInitialized());
        require(ERC20(_t0) == t0, ErrWrongTokenAddress());
        require(ERC20(_t1) == t1, ErrWrongTokenAddress());
        require(_t0Amount > 0, ErrInputIsZero());
        require(_t1Amount > 0, ErrInputIsZero());

        balances[_t0] += _t0Amount;
        balances[_t1] += _t1Amount;

        ratioK = calculateConstant();

        _mint(address(0), 1000);// locking forever

        uint _lpShare = _calcLpShare(_t0Amount, _t1Amount);
        _mint(msg.sender, _lpShare);

        return ratioK;
    }

    // returns product of two amounts
    function calculateConstant() private view returns (uint) {
        return balances[t0Addr]*balances[t1Addr];
    }

    function addLiquidity(uint _t0Amount, uint _t1Amount) external returns (uint) {
        require(_t0Amount != 0, ErrInputIsZero());
        require(_t1Amount != 0, ErrInputIsZero());

        t0.transferFrom(msg.sender, address(this), _t0Amount);
        t1.transferFrom(msg.sender, address(this), _t1Amount);

        _addLiquidity(_t0Amount, _t1Amount, false);

        return ratioK;
    }

    function _addLiquidity(uint _t0Amount, uint _t1Amount, bool isInitial) private returns (uint) {
        require(_t0Amount != 0, ErrInputIsZero());
        require(_t1Amount != 0, ErrInputIsZero());

        bool r0 = t0.transferFrom(msg.sender, address(this), _t0Amount);        
        bool r2 = t1.transferFrom(msg.sender, address(this), _t1Amount);

        require(r0 && r2, ErrTokensTransferFailed());

        if(false == isInitial) {
            ratioK = calculateConstant();
        }
        

        _addToLp(_t0Amount, _t1Amount);

        uint _lpShare = _calcLpShare(_t0Amount, _t1Amount);
        _mint(msg.sender, _lpShare);

        return ratioK;
    }

    // it returns the share of the LP from the pool
    // in percentage
    function _addToLp(uint _t0Amount, uint _t1Amount) private returns (uint) {
        t0LpBalance[msg.sender] += _t0Amount;
        t1LpBalance[msg.sender] += _t1Amount;
    }

    function subtractFromLp(uint _t0Amount, uint _t1Amount) private {
        t0LpBalance[msg.sender] -= _t0Amount;
        t1LpBalance[msg.sender] -= _t1Amount;
    }

    function swap(address tokenIn, uint amountIn) external returns (address, uint) {
        require(tokenIn != t0Addr && tokenIn != t1Addr, ErrWrongTokenAddress());
        require(amountIn > 0, ErrInputIsZero());
        require(balances[tokenIn]-amountIn > 0, ErrNotEnoughLiquidity());
        (uint newAmountIn, uint fee) = _calcFee(amountIn);
        (address tokenOut, uint tokenOutAmount) = _calcPair(tokenIn, amountIn);
    }

    // the caller has to do the validation
    // it uses Solidity's default rounding down. So if 
    // the formula results in zero fee, then no fee is charged
    // it returns both the amount [minus] fee and fee
    function _calcFee(uint amount) internal pure returns (uint, uint) {
        if(amount == 1 || amount == 0) {
            return (amount, 0);
        }
        uint fee = (amount * feePercentage) / 100;
        return (amount-fee, fee);
    }

    function _calcCumulativePrices() internal returns (uint240, uint240) {
        
    }

    function fixedNumber(n uint120) internal pure returns (uint240) {
        return uint240(n * Q120);
    }

    // the caller has to do the validation
    // returns tokenOut address as well as the amount of tokenOut calculated
    function _calcPair(address tokenIn, uint amountIn) internal returns (address, uint) {
        address tokenOut = t1Addr;
        if(tokenIn == t1Addr) {
            tokenOut = t0Addr;
        }
        balances[tokenIn] = balances[tokenIn]+amountIn;

        uint tokenOutAmount = ratioK / balances[tokenIn];
        return (tokenOut, tokenOutAmount);
    }

    function _calcLpShare(uint t0, uint t1) returns (uint) {
        return sqrt(t0 * t1);
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