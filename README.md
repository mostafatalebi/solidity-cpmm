### Automatic Market Maker in Solidity

CPMM in Solidity.

It uses Constant Product Market Maker to manage paired token pricing.

It exposes three public functions: 

### addLiquidity()
Used for adding liquidity to the pool. It forces the current ratio to unrealistic price slippage.

Requires the caller to first approve() transfer of the tokens (two tokens of the pair). The caller will recieve
an amount of LP proportional to the amounts contributed to the pool.

### burnLiquidity()
Used to remove liquidity. It requires the caller to first approve() transfer of n amout of
his/her LP tokens. A calculated amount of both tokens based on the amount of LP relative to the 
whole pool size will be sent to the caller.

### swap()
Used by traders, allows swapping an amount of token for the other token. 
A ratio is forced to avoid unrealistic pricing shifts. 