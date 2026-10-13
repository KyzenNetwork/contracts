# Kyzen Network contracts

The Solidity contracts of Kyzen Network on Robinhood Chain, with their Foundry tests.

## Mainnet (Robinhood Chain, chain ID 4663)

| Contract | Address | Source |
|---|---|---|
| $KYZN token | `0x9b3A765a32F3ff0623a2dEa04136960C77205B09` | `src/KyznToken.sol` |
| Reserve | `0x8112e96d514787BDDA67E6A6B2432Ab229a1045e` | `src/Reserve.sol` |
| Staking | `0x76E274064f6d047206D3d164332D143C52a08c0a` | `src/Staking.sol` |
| Weight registry | `0x9960eb28D2fb78A901E310dd2aB99Ba4ea227d09` | `src/WeightRegistry.sol` |
| Gateway settlement | `0xe4EdA9794c24c81fB68871AF6e08f2d0519415D2` | `src/GatewaySettlement.sol` |

Each one is verified on Sourcify (exact match) and on Blockscout, compiled with solc 0.8.37, optimizer on at 200 runs, EVM version cancun (`foundry.toml`). Every recorded address is in `deployments/4663.json`. To check them from a terminal: `kyzen verify` ([Kyzen Network CLI](https://github.com/KyzenNetwork/cli)).

## Silicon (Gen 2)

`src/silicon` holds the Silicon synthetics: the four chip-stock stage indices (`StockIndexFeed`, `MarketCalendar`), the collateral vault with its Dutch-auction liquidations (`SiliconVault`), the $KYZN price oracle (`KyznUsdOracle`), the synths and the fee router. They run on the Robinhood Chain testnet (46630, `deployments/46630.json`) and are not deployed on mainnet yet. Each index's methodology is published at `https://docs.kyzen.network/methodology/<index>.txt`; `methodology-hashes.json` holds the keccak-256 of each text, which the deployment records on chain.

## Build and test

[Foundry](https://book.getfoundry.sh) with Soldeer:

```sh
forge soldeer install
forge build
forge test --no-match-path 'test/fork/*'
```

The tests cover each contract with unit, fuzz and invariant suites. The suites under `test/fork` read Robinhood Chain mainnet and testnet through their public RPCs (`foundry.toml`), so they need a network connection.

## Layout

- `src/`: the contracts.
- `test/`: unit, fuzz and invariant tests, mocks, and fork tests against Robinhood Chain.
- `script/`: deployment scripts for mainnet and the testnet.
- `deployments/`: the recorded addresses per chain.
- `external/uniswap-v2/`: Uniswap v2 build artifacts deployed unmodified on the testnet, under Uniswap's own license (GPL-3.0-or-later, see its `LICENSE-NOTICE.md`).

## License

MIT, except `external/uniswap-v2` (see above). Website: https://kyzen.network · Docs: https://docs.kyzen.network
