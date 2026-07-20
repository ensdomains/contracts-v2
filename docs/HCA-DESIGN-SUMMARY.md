# HCA design summary

The HCA executes registration and remains a resolver delegate. The wallet owns the name, receives resolver `ROLES.ALL`, and can revoke the HCA's resolver roles.

- Built: standalone HCA, wallet-paid batches, owner-signed ERC-4337 execution, owner-bound deployment, and a Bun-patched SDK adapter.
- Live: fresh and existing same-chain registration on Sepolia; fresh Arbitrum Sepolia-to-Sepolia registration with two signatures, zero wallet transactions, and USDC-paid execution.
- Local: fresh deploy-and-execute through a paymaster.
- Remaining: publish the SDK adapter, integrate Manager, test a production paymaster, and complete the protocol release work.

| Need | Document |
|---|---|
| Design and open decisions | [HCA design](./HCA-DESIGN.md) |
| Frontend routes, calls, counts, and devnet | [Frontend handoff](./HCA-HANDOFF-FRONTEND.md) |
| Contract security work | [Protocol handoff](./HCA-HANDOFF-PROTOCOL.md) |
| SDK adapter and routing work | [Rhinestone handoff](./HCA-HANDOFF-RHINESTONE.md) |

Mockestrator is local transport, not a working standalone-HCA frontend integration.
