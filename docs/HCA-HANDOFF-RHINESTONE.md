# ENS v2 HCA: Rhinestone handoff

## Goal

Support the standalone HCA with the existing intent, session, and Permit2 machinery. Keep legacy HCA behavior unchanged.

## Standalone HCA adapter

Treat the standalone account as another HCA version. Its configuration supplies the deployer, implementation, fixed validator, `VerifiableFactory`, proxy logic, and user salt.

```text
deploymentSalt = keccak256(abi.encode(userSalt, owner, implementation))
factory = StandaloneHCADeployer
factoryData = deploy(owner, implementation, userSalt)
```

Derive the proxy address from `VerifiableFactory`, the deployer, and `deploymentSalt`. For a fresh HCA, include `factoryData` in the first intent. For an existing HCA, verify its owner and supported implementation and omit deployment.

Use the fixed validator as the account's default validator for owner signatures, session status, estimation, and mock signatures. The standalone HCA cannot install arbitrary modules.

For ERC-4337, keep the existing owner UserOperation signature format. Encode the fixed validator as Nexus's default validator in the nonce, and return the deployer call as the account's factory data. A fresh account can then deploy and execute in one UserOperation; an existing account omits factory data. Existing bundler and paymaster configuration applies.

ENS supplies the deployed addresses, implementation-to-validator mapping, ABI, user-salt policy, and address fixtures.

The handoff is the standalone-HCA adapter. Cross-chain execution uses the existing Nexus, Permit2, and Across paths.

## Same-chain fixed sessions

No orchestrator change is required. Use the existing `SingleChainOps` route in ERC-1271 mode.

The session key signs the existing `SingleChainOps` digest. The standalone adapter then packs the account signature as:

```text
address(0)
|| 0x01
|| permissionId
|| nonce
|| operationData
|| sessionSignature

operationData = op.vt || abi.encode(op.ops)
```

`sessionSignature` is the existing 65-byte ECDSA signature from the Smart Session `USE` payload. The permission ID and typed-data schema do not change. For a user-paid route, the adapter also packs the existing `GasRefund` tuple. The validator binds it to the session's token and limits.

## Cross-chain Permit2

No orchestrator change is required. Use a counterfactual Nexus as the source account and the standalone HCA as the recipient. The target mode is ERC-1271.

For a fresh USDC wallet, include `USDC.permit(...)` and `USDC.transferFrom(wallet, Nexus, amount)` in the source calls. The route deploys the Nexus, pulls the source budget, approves Permit2, claims the required funds, and executes through the HCA.

Keep the existing Permit2 typed data and signing behavior. Both accounts use the `address(0)` signature prefix to select their configured default validator. With the same single ECDSA owner, the Nexus Permit2 signature is already a valid HCA signature:

```text
destinationSignature = originSignatures[0]
```

Do not request another destination signature. Do not use an EOA source: that route does not select ERC-7579 execution and calls the destination operations from the Across handler.

The live user-paid flow is:

1. The wallet signs the EIP-2612 permit.
2. The wallet signs one Permit2 intent.
3. Rhinestone deploys the source Nexus, pulls the budget, and submits the claim.
4. The fill deploys and funds the HCA, enables a refund-bounded session, and commits.
5. After the delay, the session reveals without another wallet prompt.

This is two signatures and zero wallet transactions for a fresh wallet. Connection and a conditional network switch are not counted.

## Outside Rhinestone

Wallet-paid `executeByOwner` routes through the user's wallet and does not use Rhinestone.

## Acceptance

- Address derivation matches the deployed contract for fresh and existing HCAs.
- Fresh same-chain setup can deploy the HCA and submit the commitment in one intent.
- A fresh owner UserOperation can deploy the HCA and execute through a paymaster.
- Owner-signed and fixed-session same-chain intents work with the production executor.
- Existing HCAs are reused without a deployment operation.
- Legacy HCA behavior is unchanged.
- Cross-chain Permit2 reuses one wallet signature for source and destination authorization.
- Cross-chain permissionless deployment and commitment complete before signing.
- One Permit2 signature authorizes the source claim and HCA registration batch.
- Cross-chain destination calls execute through the HCA.
- User-paid sessions bind Rhinestone's existing refund fields and fixed refund paymaster.

Fresh and existing same-chain registration passed on Sepolia with the patched SDK. A fresh zero-ETH wallet also passed live from Arbitrum Sepolia to Sepolia with two signatures, zero wallet transactions, an unsponsored USDC claim and fill, and USDC-paid session commit and reveal. CI covers SDK refund packing, Permit2 signature reuse, and fresh UserOperation factory data; the contract test executes paymaster-sponsored deployment through EntryPoint. Publishing the standalone adapter and testing a production paymaster remain.

Run `bun run check:hca-live:permit-pull` from `contracts/`. It generates a fresh owner, submits the Arbitrum Sepolia-to-Sepolia two-signature route, completes two registrations, checks USDC charges, and verifies ownership and resolver roles.
