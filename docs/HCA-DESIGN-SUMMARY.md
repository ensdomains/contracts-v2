# HCA design summary

The HCA executes registration and remains a resolver delegate. The wallet owns the name, receives resolver `ROLES.ALL`, and can revoke the HCA's resolver roles.

This branch has a standalone HCA, an owner-bound deployer, and local tests. Manager still uses the legacy HCA. Production security, funding, routing, and app integration remain incomplete.

| Need | Document |
|---|---|
| Design and open decisions | [HCA design](./HCA-DESIGN.md) |
| Frontend routes, calls, counts, and devnet | [Frontend handoff](./HCA-HANDOFF-FRONTEND.md) |
| Contract security work | [Protocol handoff](./HCA-HANDOFF-PROTOCOL.md) |
| SDK, typed data, and routing work | [Rhinestone handoff](./HCA-HANDOFF-RHINESTONE.md) |

Mockestrator is local transport, not a working standalone-HCA frontend integration.
