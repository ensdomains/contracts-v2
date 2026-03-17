# Indexing ENSv2 Test Names

This document explains the test data created by `contracts/script/testNames.ts` and how an indexer (such as [v2-mini-indexer](https://github.com/ensdomains/ensv2-indexer)) would index each name by listening to on-chain events.

## Overview

The `testNames()` function sets up a devnet with various ENS names in different states. Each operation emits specific contract events that an indexer must process to build a complete picture of the namespace.

## Test Data Summary

| Name | Operation | Expected Indexed State |
|------|-----------|----------------------|
| `test.eth` | Register | Domain with owner, resolver (addr + text records) |
| `example.eth` | Register | Domain with owner, resolver |
| `demo.eth` | Register | Domain with owner, resolver |
| `newowner.eth` | Register + Transfer | Domain owned by `user` account (not `owner`) |
| `renew.eth` | Register + Renew (365 days) | Domain with extended expiry |
| `reregister.eth` | Register + Expire + Re-register | Domain with new expiry and new tokenId |
| `parent.eth` | Register | Domain with owner, resolver |
| `changerole.eth` | Register + Role change | Domain with modified EAC roles, new tokenId |
| `alias.eth` | Register + Set alias to `test.eth` | Domain sharing resolver with `test.eth`; alias record set |
| `sub.alias.eth` | Records set on `test.eth` resolver | Resolves via alias chain (no direct registry entry) |
| `sub2.parent.eth` | Create subname (UserRegistry) | Subname with dedicated UserRegistry and resolver |
| `sub1.sub2.parent.eth` | Create subname (UserRegistry) | Nested subname |
| `wallet.sub1.sub2.parent.eth` | Create subname (UserRegistry) | Deeply nested subname |
| `linked.parent.eth` | Link to `sub1.sub2.parent.eth` subregistry | Shares subregistry with `sub1.sub2.parent.eth` |
| `wallet.linked.parent.eth` | Shared token via linked subregistry | Same token as `wallet.sub1.sub2.parent.eth` |
| `reserved.eth` | Reserve (no owner) | Domain with RESERVED status, no token minted |
| `unregistered.eth` | Register + Unregister | Domain returned to AVAILABLE status, token burned |

## Setup: Parent Registry Links

Before registering names, `testNames()` calls `ETHRegistry.setParent(RootRegistry, "eth")` to establish the child→parent link. This emits:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `ParentUpdated(parent, label, sender)` | `IRegistry` (ETHRegistry) | Parent registry address, label in parent |

**Indexer action**: Record the parent registry and label for the ETHRegistry. This enables reconstructing full domain names by traversing the parent chain (e.g., ETHRegistry → "eth" in RootRegistry → root).

## Events Emitted Per Operation

### 1. Name Registration (`registerTestNames`)

Each name registration triggers events on the **ETHRegistry** (a `PermissionedRegistry`):

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameRegistered(tokenId, labelHash, label, owner, expiry, ...)` | `IRegistry` | tokenId, label, owner, expiry |
| `TransferSingle(operator, from=0x0, to, id, value)` | `ERC1155Singleton` | Mint event: `from=address(0)` |
| `TokenResource(tokenId, resource)` | `IPermissionedRegistry` | Links tokenId to its resource/canonical ID |

Each registration also deploys a **PermissionedResolver** and sets records:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `AddressChanged(node, coinType=60, address)` | Resolver | ETH address record |
| `TextChanged(node, key="description", value)` | Resolver | Text record |

**Indexer action**: Create a `Domain` entry with name, namehash, owner, expiry, resolver address. Create `Registration` entry. Index resolver records.

### 2. Transfer (`transferName`)

Transferring `newowner.eth` to the `user` account:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `TransferSingle(operator, from=owner, to=user, id=tokenId, value=1)` | `ERC1155Singleton` | Ownership change |

**Indexer action**: Update domain `owner` field. The `registrant` (original registerer) remains unchanged.

### 3. Renewal (`renewName`)

Renewing `renew.eth` for 365 days via the ETHRegistrar:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameRenewed(label, newExpiry)` | `IETHRegistrar` | Updated expiry |
| `ExpiryUpdated(tokenId, newExpiry, sender)` | `IRegistry` | Updated expiry on registry |

**Indexer action**: Update domain `expiryDate`.

### 4. Re-registration (`reregisterName`)

Time-warps past expiry, then re-registers with a new expiry:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameRegistered(tokenId, labelHash, label, owner, expiry, ...)` | `IRegistry` | New tokenId (different from original) |
| `TransferSingle(operator, from=0x0, to, id, value)` | `ERC1155Singleton` | New mint |
| `TokenResource(tokenId, resource)` | `IPermissionedRegistry` | New tokenId-to-resource mapping |

**Indexer action**: The domain gets a new tokenId. Update the domain entry, reset expiry. The canonical ID (resource) stays the same but the tokenId changes.

### 5. Subname Creation (`createSubname`)

Creating `wallet.sub1.sub2.parent.eth` involves multiple levels:

For each level (sub2, sub1, wallet):

1. **Deploy UserRegistry** (UUPS proxy):

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| (Proxy deployment events) | `VerifiableFactory` | New registry address |

2. **Set subregistry on parent**:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `SubregistryUpdated(tokenId, subregistry, sender)` | `IRegistry` | Parent tokenId linked to child registry |

3. **Set parent on new UserRegistry**:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `ParentUpdated(parent, label, sender)` | `IRegistry` (UserRegistry) | Links child registry back to its parent |

4. **Register subname in UserRegistry**:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameRegistered(tokenId, labelHash, label, owner, expiry, ...)` | `IRegistry` (UserRegistry) | Subname registration |
| `TransferSingle(operator, from=0x0, to, id, value)` | `ERC1155Singleton` | Mint in UserRegistry |
| `ResolverUpdated(tokenId, resolver, sender)` | `IRegistry` | Resolver set on subname |

**Indexer action**: The indexer must **dynamically discover** new UserRegistry contracts by watching `SubregistryUpdated` events. Once discovered, the indexer adds the new registry address to its watch list and starts indexing events from it. The `ParentUpdated` events allow the indexer to reconstruct the full name hierarchy by traversing child→parent links. This is the key "hierarchical registry tracking" feature.

### 6. Name Linking (`linkName`)

Creating `linked.parent.eth` that shares the subregistry of `sub1.sub2.parent.eth`:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameRegistered(tokenId, labelHash, "linked", owner, expiry, ...)` | Parent UserRegistry | New name in registry |
| `TransferSingle(...)` | `ERC1155Singleton` | Mint |

The key detail: `linked.parent.eth` points to the **same subregistry** as `sub1.sub2.parent.eth`. This means `wallet.linked.parent.eth` and `wallet.sub1.sub2.parent.eth` resolve to the same token in the same UserRegistry.

An alias is also set on the wallet resolver so that resolver records work correctly:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `AliasChanged(name, alias)` | `PermissionedResolver` | Resolver alias mapping |

**Indexer action**: Register `linked.parent.eth` as a normal domain. Its `SubregistryUpdated` points to the already-known UserRegistry. Children resolve through shared subregistry.

### 7. Alias Creation

`alias.eth` is registered with `test.eth`'s resolver, then an alias is set:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameRegistered(...)` | `IRegistry` | alias.eth registration |
| `AliasChanged(dnsEncode("alias.eth"), dnsEncode("test.eth"))` | `PermissionedResolver` | Alias mapping |

`sub.alias.eth` has no direct registry entry. Records for `sub.test.eth` are set on test.eth's resolver, and the `UniversalResolverV2` follows the alias chain to resolve `sub.alias.eth` to `sub.test.eth`'s records.

**Indexer action**: Index alias records. Resolution of `sub.alias.eth` happens at query time through the UniversalResolver, not via direct registry lookups.

### 8. Role Changes (`changeRole`)

Granting `SET_RESOLVER` and revoking `SET_SUBREGISTRY` on `changerole.eth`:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `TokenRegenerated(oldTokenId, newTokenId)` | `IRegistry` | TokenId changes when roles change |
| `TransferSingle(operator, from, to=0x0, oldTokenId, 1)` | `ERC1155Singleton` | Burn old token |
| `TransferSingle(operator, from=0x0, to, newTokenId, 1)` | `ERC1155Singleton` | Mint new token |

**Indexer action**: Update domain tokenId. The canonical ID / resource remains stable. For details on the access control system, see [Access Control](https://github.com/ensdomains/contracts-v2/tree/main/contracts#access-control).

### 9. Reservation (`reserveName`)

Reserving `reserved.eth` with no owner:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameReserved(tokenId, labelHash, label, expiry, sender)` | `IRegistry` | tokenId, label, expiry |

**Indexer action**: Create a domain entry with `RESERVED` status. No owner is set and no ERC1155 token is minted.

### 10. Unregistration (`unregisterName`)

Registering then unregistering `unregistered.eth`:

| Event | Source | Indexed Fields |
|-------|--------|---------------|
| `NameUnregistered(tokenId, sender)` | `IRegistry` | tokenId |
| `TransferSingle(operator, from=owner, to=0x0, id=tokenId, value=1)` | `ERC1155Singleton` | Burn event |

**Indexer action**: Mark the domain as `AVAILABLE`. The ERC1155 token is burned.
