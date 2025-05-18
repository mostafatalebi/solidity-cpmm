### Automatic Market Maker in Solidity

CPMM in Solidity.

It allows to create a liquidity pool for a pair of ERC20 compatible tokens. 

I used Uniswap V2 as my reference. The contract uses another ERC20 contract for its tests which are written typescript. 

The contract is not finished and needs some more features to be added (such as LP be able to remove his liquidity).

Currently the contract exposes swap() and addLiquidity() function for interacting with the pool. We need to add further
functions (such as burn()) into the pool as well.

Tests are written in hardhat, mocha and chai using typescript. 