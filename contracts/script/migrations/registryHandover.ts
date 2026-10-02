/// Hands the deployer's authority over the v2 registries to its final holders.
///
/// The deploy leaves the deployer holding root roles on `RootRegistry` and
/// `ETHRegistry`, and the `eth` entry's roles in the root. After the migration:
/// - the owner (the DAO on mainnet) takes the root registry's root roles, admin
///   bits included, for a probation period before it drops them itself;
/// - the owner takes the `.eth` registry's root roles, so it can authorize
///   registrars and migration controllers. None of them reaches a name, so `.eth`
///   names stay emancipated;
/// - the owner can set the `eth` entry's child registry and resolver. Admin roles on
///   a name cannot be granted, so nobody can grant or revoke those roles.
///
/// This module plans the calls from the roles currently held, so a re-run sends only
/// what is missing. It knows nothing about signing or sending them.

import type { Address } from "viem";

import { DEPLOYMENT_ROLES } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// The roles the deployer and the owner currently hold, as the plan reads them.
export type RegistryHandoverState = {
  deployer: Address;
  owner: Address;
  /// Resource id of the `eth` entry in `RootRegistry`.
  ethResource: bigint;
  /// `RootRegistry` root roles of the owner.
  ownerRootRoles: bigint;
  /// `RootRegistry` root roles of the deployer.
  deployerRootRoles: bigint;
  /// Roles the owner holds on the `eth` entry.
  ownerEthEntryRoles: bigint;
  /// Roles the deployer holds on the `eth` entry.
  deployerEthEntryRoles: bigint;
  /// `ETHRegistry` root roles of the owner.
  ownerEthRegistryRoles: bigint;
  /// `ETHRegistry` root roles of the deployer.
  deployerEthRegistryRoles: bigint;
};

export type RegistryHandoverCall = {
  registry: "RootRegistry" | "ETHRegistry";
  functionName:
    | "grantRootRoles"
    | "grantRoles"
    | "revokeRootRoles"
    | "revokeRoles";
  args: readonly [bigint, Address] | readonly [bigint, bigint, Address];
  label: string;
};

/// The calls that take the registries from `state` to the handed-over end state, in
/// order. Every grant to the owner comes before the deployer's revocations, while the
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

  const calls: RegistryHandoverCall[] = [];
  const missingRoot =
    DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT & ~state.ownerRootRoles;
  if (missingRoot !== 0n) {
    calls.push({
      registry: "RootRegistry",
      functionName: "grantRootRoles",
      args: [missingRoot, state.owner],
      label: `grant the owner ${state.owner} the root registry's root roles`,
    });
  }
  const missingEthEntry =
    DEPLOYMENT_ROLES.ETH_TOKEN_OPERATOR & ~state.ownerEthEntryRoles;
  if (missingEthEntry !== 0n) {
    calls.push({
      registry: "RootRegistry",
      functionName: "grantRoles",
      args: [state.ethResource, missingEthEntry, state.owner],
      label: `let the owner ${state.owner} set the eth entry's child registry and resolver`,
    });
  }
  const missingEthRegistry =
    DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT & ~state.ownerEthRegistryRoles;
  if (missingEthRegistry !== 0n) {
    calls.push({
      registry: "ETHRegistry",
      functionName: "grantRootRoles",
      args: [missingEthRegistry, state.owner],
      label: `grant the owner ${state.owner} the .eth registry's root roles`,
    });
  }
  if (state.deployerRootRoles !== 0n) {
    calls.push({
      registry: "RootRegistry",
      functionName: "revokeRootRoles",
      args: [state.deployerRootRoles, state.deployer],
      label: "revoke the deployer's root registry root roles",
    });
  }
  if (state.deployerEthEntryRoles !== 0n) {
    calls.push({
      registry: "RootRegistry",
      functionName: "revokeRoles",
      args: [state.ethResource, state.deployerEthEntryRoles, state.deployer],
      label: "revoke the deployer's roles on the eth entry",
    });
  }
  if (state.deployerEthRegistryRoles !== 0n) {
    calls.push({
      registry: "ETHRegistry",
      functionName: "revokeRootRoles",
      args: [state.deployerEthRegistryRoles, state.deployer],
      label: "revoke the deployer's .eth registry root roles",
    });
  }
  return calls;
}

/// The root roles the owner drops to emancipate root names: everything it holds on
/// the root registry except the regular naming and metadata roles it was granted at
/// deploy. Zero once emancipated.
export function rootEmancipationRoles(ownerRootRoles: bigint): bigint {
  return ownerRootRoles & ~DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER;
}
