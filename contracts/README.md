![Build status](https://github.com/ensdomains/contracts-v2/actions/workflows/main.yml/badge.svg?branch=main)
[![codecov](https://codecov.io/github/ensdomains/contracts-v2/graph/badge.svg?branch=main)](https://codecov.io/github/ensdomains/contracts-v2)

# ENSv2 Contracts

This repository hosts the smart contracts for ENSv2 (Ethereum Name Service version 2), a next-generation naming system designed for scalability and cross-chain functionality. For comprehensive architectural details, see the [ENSv2 design doc](http://go.ens.xyz/ensv2).

## Overview

ENSv2 transitions from a flat registry to a hierarchical system that enables:

- **Flexible Ownership**: Custom registry implementations for different ownership models
- **Backward Compatibility**: Unmigrated ENSv1 names continue to function
- **Gas Efficiency**: Optimized storage and access control patterns

### Key Features

1. **Hierarchical Registries**: Each name has its own registry contract managing its subdomains
2. **Canonical ID System**: Canonical internal token ID enables for external token ID to be changed but still map to the same internal data
3. **Role-Based Access Control**: Gas-efficient access control supporting up to 32 roles
4. **Universal Resolver**: Single entry point for all name resolution
5. **Migration Framework**: Transition path from ENSv1 to ENSv2

## Architecture

### Core Concepts

**Registries**

- Each registry is responsible for one name and its direct subdomains
- Registries implement ERC1155, treating subdomains as NFTs
- Must implement the `IRegistry` interface for standard resolution
- Each registry stores its own data directly via an internal `_entries` mapping

**Root Registry** → **TLD Registries** (.eth, .box, etc.) → **Domain Registries** (example.eth) → **Subdomain Registries** (sub.example.eth)

**Resolution Process**

1. Start at root registry
2. Recursively traverse to find the deepest registry with a resolver set
3. Query that resolver for the requested record
4. Supports wildcard resolution (parent resolver handles subdomains)

### Mutable Token ID System

Token IDs representing names get regenerated in the following scenarios:

- **When an expired name is re-registered** - re-generating the token id resets the roles previously assigned against the name, ensuring that the new owner can know that only the roles they assign from then onwards are valid.

- **When the roles on a name are changed** - regenerating the token id in this case prevents griefing attacks - e.g a name is put up for sale on an NFT marketplace by an owner who then changes the permissions on it without a prospective buying knowing.

The system accomplishes this through the concept of a _canonical id_ which is the internal representation of a given name's current token id:

`canonicalId = tokenId ^ uint32(tokenId)`

The canonical id is used internally for:

- Checking role-based permissions for the name.
- Reading/writing storage data - expiry date, registry address, resolver address, etc.

### Access Control

ENSv2 uses **EnhancedAccessControl (EAC)**, a general-purpose access control base class. Compared to OpenZeppelin's roles modifier, EAC adds two key features:

1. **Resource-scoped permissions** - Roles are assigned to specific resources (e.g., individual names) rather than contract-wide.
2. **Paired admin roles** - Each base role has exactly one corresponding admin role (and vice-versa).

#### How EAC Works

Roles are assigned for a given `address` against a given resource (a `uint256` id that can represent anything).

Note that there is a special resource `0` (also known internally as `ROOT_RESOURCE`). This functions as a contract-level resource, i.e. roles assigned against this resource are considered to be at "root-level" and are thus automatically applicable to all other resources. For example, if the `ROLE_SET_RESOLVER` role is assigned for a user at the root level of a given registry contract then that user can set the resolver for any and all names within the registry.

Technical details:

- Each role is represented by a 4-bit "nybble" within a `uint256` bitmap. Given that each role has a corresponding admin role this means there are a **maximum of 32 roles** and 32 corresponding admin roles.

- Normal roles are stored in the lower 128 bits of the `uint256` role bitmap. The corresponding admin roles are stored in the upper 128 bits. For a given role its admin role is found by calculating `role << 128`.

- For a given resource, a **maximum of 15 assigness** can have a given role in that resource.

- Assigning a role via the external methods (`grantRole`, `revokeRole`, etc) requires the caller to hold the corresponding admin role for that role.

- Admin roles cannot be assigned to someone else via the external EAC methods. This means admin roles can only be granted via internal logic in derived contracts.

- Admin roles can, however, be revoked from oneself.

=**Permission Inheritance**: When checking permissions for a resource, EAC combines (via bitwise OR) the roles from:

- The specific resource (e.g., your name's permissions)
- The root resource (root-level permissions)

#### EAC in Registry Contracts

In registry contracts, EAC is used with these specific behaviors:

**Resource ID Generation**: Resource IDs the canonical token ids (see above).

**Registry-Specific Roles**: From [`RegistryRolesLib.sol`](src/registry/libraries/RegistryRolesLib.sol):

| Role                      | Bit Position | Admin Bit Position | Description                                                            |
| ------------------------- | ------------ | ------------------ | ---------------------------------------------------------------------- |
| `ROLE_REGISTRAR`          | 0            | 128                | Can register new names (root-only)                                     |
| `ROLE_RENEW`              | 4            | 132                | Can renew name registrations                                           |
| `ROLE_SET_SUBREGISTRY`    | 8            | 136                | Can change subregistry addresses                                       |
| `ROLE_SET_RESOLVER`       | 12           | 140                | Can change the resolver address                                        |
| `ROLE_CAN_TRANSFER_ADMIN` | -            | 144                | Auto-granted to new name owner. Revoking this creates a soulbound NFT. |

**Note**: `ROLE_REGISTRAR` is a root-only role since creating new subnames has no logical resource-specific equivalent (the resource doesn't exist yet).

**Admin Role Capabilities**

- In registries, **only the name owner can hold admin roles**
- **Why this restriction?** To prevent granting admin rights to another account and retaining control after a transfer. While theoretically secure (auditable), this was judged too risky.
- Admin roles can be revoked from oneself. The `ROLE_CAN_TRANSFER_ADMIN` role is one such example - this role is automatically granted to the owner of a name when the name is registered. Revoking this admin role will essentially make the name soulbound and un-transferrable.

**Transfer Behavior**

- When you transfer a name, **all roles and admin roles** transfer to the new owner
- Existing **roles** delegated to other accounts remain intact unless explicitly revoked
- Example: If Alice granted Bob `ROLE_SET_RESOLVER` and transfers the name to Charlie, Charlie becomes the new admin but Bob keeps his resolver permission

#### Usage Examples

```solidity
// Grant a base role for a specific name
registry.grantRoles(tokenId, ROLE_SET_RESOLVER, alice);

// Grant multiple roles at once
uint256 roles = ROLE_SET_RESOLVER | ROLE_SET_SUBREGISTRY;
registry.grantRoles(tokenId, roles, operator);

// Set global permissions (requires registry owner)
registry.grantRoles(ROOT_RESOURCE, ROLE_SET_RESOLVER, admin);

// Check permissions
registry.hasRoles(tokenId, ROLE_SET_RESOLVER, alice);
```

#### Creating Emancipated Names

You can create the equivalent of Name Wrapper "emancipated" names by:

1. Creating a subregistry where the owner has no root roles
2. Locking the subregistry into the parent registry
3. Result: Parent registry owner cannot interfere with subname operations

#### Example Usage

```solidity
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";

// Scenario: Delegate resolver management without transfer rights
(uint256 tokenId, ) = registry.getNameData("example");

// Grant only resolver permissions
registry.grantRoles(
    tokenId,
    RegistryRolesLib.ROLE_SET_RESOLVER,
    resolverManager
);

// Grant multiple roles at once
uint256 operatorRoles = RegistryRolesLib.ROLE_SET_RESOLVER |
                        RegistryRolesLib.ROLE_SET_SUBREGISTRY;
registry.grantRoles(tokenId, operatorRoles, operator);

// Check if user has required permissions
bool canSetResolver = registry.hasRoles(
    tokenId,
    RegistryRolesLib.ROLE_SET_RESOLVER,
    user
);

// Admin can grant roles to others
registry.grantRoles(
    tokenId,
    RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN,
    admin
);
```

## Contract Documentation

### Registry System

#### `IRegistry` - Core Interface

[src/registry/interfaces/IRegistry.sol](src/registry/interfaces/IRegistry.sol)

Standard interface all registries must implement:

```solidity
interface IRegistry is IERC1155Singleton {
  event NameRegistered(uint256 indexed tokenId, bytes32 indexed labelHash, string label, address owner, uint64 expiry, address indexed sender);
  event NameReserved(uint256 indexed tokenId, bytes32 indexed labelHash, string label, uint64 expiry, address indexed sender);
  event NameUnregistered(uint256 indexed tokenId, address indexed sender);
  event ExpiryUpdated(uint256 indexed tokenId, uint64 newExpiry, address indexed sender);
  event SubregistryUpdated(uint256 indexed tokenId, IRegistry subregistry, address indexed sender);
  event ResolverUpdated(uint256 indexed tokenId, address resolver, address indexed sender);
  event TokenRegenerated(uint256 indexed oldTokenId, uint256 indexed newTokenId);

  function getSubregistry(string calldata label) external view returns (IRegistry);
  function getResolver(string calldata label) external view returns (address);
}
```

#### `PermissionedRegistry` - Standard Implementation

[src/registry/PermissionedRegistry.sol](src/registry/PermissionedRegistry.sol)

Feature-complete registry with role-based access control:

- ERC1155 NFT for subdomains
- Enhanced Access Control with 32 roles
- Expiry management
- Metadata support (name, description, image)
- Direct internal storage via `_entries` mapping

**Key Functions**:

- `getEntry(uint256 anyId)`: Fetch an entry by labelhash, token ID, or resource
- `getNameData(string label)`: Fetch token ID and entry for a label
- `setSubregistry(uint256 anyId, IRegistry registry)`: Update subregistry
- `setResolver(uint256 anyId, address resolver)`: Update resolver

**Storage Structure** (defined in `IPermissionedRegistry`):

```solidity
struct Entry {
  uint32 eacVersionId;    // Version counter for access control changes (incremented on permission updates)
  uint32 tokenVersionId;  // Version counter for token regeneration (incremented on burn/remint)
  IRegistry subregistry;  // Registry contract for subdomains under this name
  uint64 expiry;          // Timestamp when the name expires (0 = never expires)
  address resolver;       // Resolver contract for name resolution data
}
```

#### `ERC1155Singleton` - Gas-Optimized NFT

[src/erc1155/ERC1155Singleton.sol](src/erc1155/ERC1155Singleton.sol)

Modified ERC1155 allowing only one token per ID:

- Saves gas by omitting balance tracking
- Provides `ownerOf(uint256 id)` like ERC721
- Emits transfer events for indexing

### Core Components

#### Migration Controllers

[src/migration/](src/migration/)

- `LockedMigrationController`: Handles ENSv1 → ENSv2 migration for locked names
- `UnlockedMigrationController`: Handles ENSv1 → ENSv2 migration for unlocked names

### Resolution

#### `UniversalResolverV2` - One-Stop Resolution

[src/universalResolver/UniversalResolverV2.sol](src/universalResolver/UniversalResolverV2.sol)

Single contract for resolving any ENS name:

- Handles recursive registry traversal
- Supports CCIP-Read for off-chain resolution
- Wildcard resolution
- Batch resolution

**Example**:

```solidity
// Resolve address
(bytes memory result, address resolver) = universalResolver.resolve(
    dnsEncodedName,
    abi.encodeWithSelector(IAddrResolver.addr.selector, node)
);
address resolved = abi.decode(result, (address));
```

## Getting started

### Installation

1. Install [Node.js](https://nodejs.org/) v24+
2. Install foundry: [guide](https://book.getfoundry.sh/getting-started/installation) v1.3.2+
3. Install [bun](https://bun.sh/) v1.2+
4. Install dependencies:
5. (OPTIONAL) Install [lcov](https://github.com/linux-test-project/lcov) if you want to run coverage tests
   - Mac: `brew install lcov`
   - Ubuntu: `sudo apt-get install lcov`

```sh
bun i
cd contracts
forge i
```

### Build

```sh
forge build
bun run compile:hardhat
```

### Test

Prior to running tests ensure you compile `lib/ens-contracts`:

```sh
cd lib/ens-contracts
bun run compile
```

Testing is done using both Foundry and Hardhat.
Run all test suites:

```sh
bun run test         # ALL tests
```

Or run specific test suites:

```sh
bun run test:hardhat  # Run Hardhat tests
bun run test:forge    # Run Forge tests
bun run test:hardhat test/Ens.t.ts # specific Hardhat test
```

## Running the Devnet

There are two ways to run the devnet:

### Native Local Devnet (recommended)

Start a local devnet:

```sh
bun run devnet        # runs w/last build
```

This will start a local chain at http://localhost:8545 (Chain ID: 31337)

### Using Docker Compose

1. Make sure you have Docker and Docker Compose installed
2. Run the devnet using either:

   ```bash
   # Using local build
   docker compose up -d

   # Or using pre-built image from GitHub Container Registry
   docker pull ghcr.io/ensdomains/contracts-v2:latest
   docker compose up -d
   ```

3. The devnet will be available at http://localhost:8545 (Chain ID: 31337)

To view logs:

```bash
docker logs -f contracts-v2-devnet-1
```

To stop the devnet:

```bash
docker compose down
```

## Miscellaneous

Foundry also comes with cast, anvil, and chisel, all of which are useful for local development ([docs](https://book.getfoundry.sh/))

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```
