# Cost of the initial pre-migration on mainnet

Estimated at block 26,081,135 (2026-09-29T05:48:59.000Z) by `bun run premigration:cost`.

| | |
|---|---|
| Names to reserve | 925,618 claimable of 3,538,126 ever registered |
| Labels known | 925,312 of the 925,618 from controller logs; the sample is drawn from these |
| Sample reserved | 5,000 names in 100 txs; 0 failed |
| Gas per name | 67,567 ± 104 (95%), all-in |
| Projected | 18,513 txs of 50 names, 62,542,074,643 gas |
| Gas price (14 days) | mean 0.73 gwei, median 0.214 gwei over 100,260 blocks |
| **Cost** | **45.6857 ETH** at the mean price (13.4093 ETH at the median) |
| Gas price limit | sends wait while the price is above 0.146 gwei, so the run pays at most 9.1311 ETH |

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
