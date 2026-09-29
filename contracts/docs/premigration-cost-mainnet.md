# Cost of the initial pre-migration on mainnet

Estimated at block 26,083,345 (2026-09-29T13:12:59.000Z) by `bun run premigration:cost`.

| | |
|---|---|
| Names to reserve | 925,155 claimable of 3,538,137 ever registered |
| Labels known | 924,849 of the 925,155 from controller logs; the sample is drawn from these |
| Sample reserved | 5,000 names in 100 txs; 0 failed |
| Gas per name | 67,462 ± 94 (95%), all-in |
| Projected | 18,504 txs of 50 names, 62,413,216,083 gas |
| Gas price (14 days) | mean 0.752 gwei, median 0.223 gwei over 100,259 blocks |
| **Cost** | **46.9449 ETH** at the mean price (13.8895 ETH at the median) |
| Gas price limit | sends wait while the price is above 0.146 gwei, so the run pays at most 9.1123 ETH |

## Method

The names are every .eth 2LD that pre-migration reserves at the block: its v1 expiry
plus the 90-day grace period lies after the block, and no Graveyard holds it. They are
rebuilt from the registrar's `NameRegistered` and `NameRenewed` logs, whose newest
event per name carries its expiry, and a sample of them is checked against the chain.
The v2 contracts pre-migration writes to were deployed on an Anvil fork at the block by
the phase 1 deploy scripts. An evenly spread sample of the names was reserved there
through pre-migration's own send path, in batches of its size. Gas per name is receipt
gas over names reserved, so it includes each transaction's base cost and calldata. The
projection scales it to every name to reserve and prices it at the mean and the median
of base fee plus median priority fee over the 14 days of blocks before the block.
