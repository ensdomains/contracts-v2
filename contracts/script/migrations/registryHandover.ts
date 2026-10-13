/// Hands the deployer's authority over the v2 registries to its final holders.
///
/// The deploy leaves the deployer holding root roles on `RootRegistry` and
/// `ETHRegistry`, the `eth` and `reverse` tokens in the root, and ownership of the
/// two batch registrars. After the migration:
/// - the name owner (the ENS DAO name owner Safe on mainnet) holds the `eth` and
///   `reverse` tokens, and with each every role and admin role on its entry;
/// - the owner (the DAO on mainnet) takes every safe root role, with its admin
///   role, on both the root registry and the `.eth` registry: registering names
///   and reserved names, setting the parent, renewing, setting the metadata URI and
///   contract naming. None of them reaches a name, so both registries leave their
///   names emancipated;
/// - the batch registrars have no owner, so nothing can ever send through them
///   again, even if a registry grants them roles.
///
/// This module plans the calls from the roles currently held, so a re-run sends only
/// what is missing. It knows nothing about signing or sending them.

import { type Address, type Hex, zeroAddress } from "viem";

import { DEPLOYMENT_ROLES } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// The contracts the handover writes to.
export type HandoverContract =
  | "RootRegistry"
  | "ETHRegistry"
  | "BatchRegistrar"
  | "RootBatchRegistrar";

/// The root registry names whose tokens the handover moves to the name owner.
export const HANDED_OVER_ROOT_NAMES = ["eth", "reverse"] as const;
export type HandedOverRootName = (typeof HANDED_OVER_ROOT_NAMES)[number];

/// What the deployer, the owner and the name owner currently hold, as the plan reads it.
export type RegistryHandoverState = {
  deployer: Address;
  owner: Address;
  nameOwner: Address;
  /// Each handed-over name's current token id in `RootRegistry`, and its holder. A
  /// role change on an entry regenerates its token id, so it is read just before the
  /// plan runs.
  rootNameTokens: Array<{
    label: HandedOverRootName;
    tokenId: bigint;
    holder: Address;
  }>;
  /// Owners of the batch registrars this namespace deployed.
  batchRegistrars: Array<{
    contract: "BatchRegistrar" | "RootBatchRegistrar";
    owner: Address;
  }>;
  /// `RootRegistry` root roles of the owner.
  ownerRootRoles: bigint;
  /// `RootRegistry` root roles of the deployer.
  deployerRootRoles: bigint;
  /// `ETHRegistry` root roles of the owner.
  ownerEthRegistryRoles: bigint;
  /// `ETHRegistry` root roles of the deployer.
  deployerEthRegistryRoles: bigint;
};

export type RegistryHandoverCall = {
  contract: HandoverContract;
  functionName:
    | "grantRootRoles"
    | "revokeRootRoles"
    | "safeTransferFrom"
    | "renounceOwnership";
  args:
    | readonly []
    | readonly [bigint, Address]
    | readonly [Address, Address, bigint, bigint, Hex];
  label: string;
};

/// The calls that take the registries from `state` to the handed-over end state, in
/// order. The `eth` and `reverse` tokens move first, while the deployer is still the
/// only account with a role on each entry, as a safe transfer requires; their roles
/// move with them.
/// Every grant to the owner comes before the deployer's revocations, while the
/// deployer still holds the admin roles that make it, so no role passes through a
/// moment with nobody able to grant it. Empty once handed over.
export function planRegistryHandover(
  state: RegistryHandoverState,
): RegistryHandoverCall[] {
  // Granting to and revoking from the same account would leave the registries with
  // no admin at all, which no later transaction could repair.
  if (sameAddress(state.owner, state.deployer)) {
    throw new Error(
      `the owner ${state.owner} is the deployer: there is no one to hand the registries to`,
    );
  }
  if (sameAddress(state.nameOwner, state.deployer)) {
    throw new Error(
      `the name owner ${state.nameOwner} is the deployer: there is no one to hand the root names to`,
    );
  }

  const calls: RegistryHandoverCall[] = [];
  for (const { label, tokenId, holder } of state.rootNameTokens) {
    if (sameAddress(holder, state.deployer)) {
      calls.push({
        contract: "RootRegistry",
        functionName: "safeTransferFrom",
        args: [state.deployer, state.nameOwner, tokenId, 1n, "0x"],
        label: `transfer the ${label} token, and every role on the entry, to the name owner ${state.nameOwner}`,
      });
    } else if (!sameAddress(holder, state.nameOwner)) {
      throw new Error(
        `the ${label} token is held by ${holder}, neither the deployer nor the name owner ${state.nameOwner}`,
      );
    }
  }
  const missingRoot =
    DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT & ~state.ownerRootRoles;
  if (missingRoot !== 0n) {
    calls.push({
      contract: "RootRegistry",
      functionName: "grantRootRoles",
      args: [missingRoot, state.owner],
      label: `grant the owner ${state.owner} the root registry's root roles`,
    });
  }
  const missingEthRegistry =
    DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT & ~state.ownerEthRegistryRoles;
  if (missingEthRegistry !== 0n) {
    calls.push({
      contract: "ETHRegistry",
      functionName: "grantRootRoles",
      args: [missingEthRegistry, state.owner],
      label: `grant the owner ${state.owner} the .eth registry's root roles`,
    });
  }
  if (state.deployerRootRoles !== 0n) {
    calls.push({
      contract: "RootRegistry",
      functionName: "revokeRootRoles",
      args: [state.deployerRootRoles, state.deployer],
      label: "revoke the deployer's root registry root roles",
    });
  }
  if (state.deployerEthRegistryRoles !== 0n) {
    calls.push({
      contract: "ETHRegistry",
      functionName: "revokeRootRoles",
      args: [state.deployerEthRegistryRoles, state.deployer],
      label: "revoke the deployer's .eth registry root roles",
    });
  }
  for (const { contract, owner } of state.batchRegistrars) {
    if (sameAddress(owner, state.deployer)) {
      calls.push({
        contract,
        functionName: "renounceOwnership",
        args: [],
        label: `renounce ownership of ${contract}, leaving it with no owner`,
      });
    } else if (!sameAddress(owner, zeroAddress)) {
      throw new Error(
        `${contract} is owned by ${owner}, neither the deployer nor nobody`,
      );
    }
  }
  return calls;
}
