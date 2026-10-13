# Uniswap v2 build artifacts

`UniswapV2Factory.json` and `UniswapV2Pair.json` come from the npm package `@uniswap/v2-core@1.0.1`,
and `UniswapV2Router02.json` from `@uniswap/v2-periphery@1.1.0-beta.0`, both published by Uniswap Labs
under GPL-3.0-or-later. Only the `abi` and the creation `bytecode` are kept. They are deployed
unmodified on the Robinhood Chain testnet (46630), where no Uniswap v2 deployment exists, so the
testnet runs the same pool code as mainnet. The pair init code hash is
`0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`, which Router02 expects.
