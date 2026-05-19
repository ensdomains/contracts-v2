# ENS Hardware-Controlled Accounts (HCA)

Smart account infrastructure for ENS hardware-backed signers, built on [Nexus](https://github.com/rhinestonewtf/rhinestone-nexus) (ERC-7579 / ERC-4337).

For full documentation, architecture details, and usage instructions, see the [HCA README](https://github.com/rhinestonewtf/ens-modules/blob/hca/README.md).

## Contracts in this directory

### `HCAFactory`

The registry that records user-designated HCA proxies:

- Lets a caller designate an already-deployed SCA as their HCA with `setAccount`.
- Records `msg.sender` as the HCA owner for each designation.
- Uses an implementation allowlist for HCA designations.
- Verifies designated SCAs through the shared `VerifiableFactory`.

### `HCAContext` / `HCAContextUpgradeable`

Context contracts providing HCA factory references and upgrade guards for HCA account implementations.

### `HCAEquivalence`

Equivalence checking utilities for HCA deployments.

## Architecture

```mermaid
flowchart TD
    Owner["User / account owner"]
    HCAFactory["HCAFactory"]
    VerifiableFactory["VerifiableFactory"]
    ImplAllowlist["approvedImplementations"]
    ExistingSCA["Existing SCA<br/>(verifiable proxy)"]
    HCAImpl["HCA implementation<br/>extends Nexus"]
    HCAModule["HCAModule<br/>default validator"]
    IntentExecutor["IntentExecutor<br/>default executor"]

    Owner -->|"setAccount(sca, implementation)"| HCAFactory
    HCAFactory -->|"checks"| ImplAllowlist
    HCAFactory -->|"verifyContract(sca, implementation)"| VerifiableFactory
    VerifiableFactory -->|"verifies deployment + implementation"| ExistingSCA
    ExistingSCA -->|"delegatecall"| HCAImpl

    HCAImpl -->|"uses"| HCAModule
    HCAImpl -->|"uses"| IntentExecutor
```

## Development

```shell
forge build
forge test
```

## License

GPL-3.0
