/// Hands the deployer's authority over the v2 registries to its final holders.
///
/// The deploy leaves the deployer holding root roles on `RootRegistry` and
/// `ETHRegistry`, and the `eth` entry's roles in the root. After the migration:
/// - the owner (the DAO on mainnet) takes the root registry's root roles, admin
///   bits included, for a probation period before it drops them itself;
/// - nobody holds an admin role on `ETHRegistry`, so `.eth` names are emancipated;
/// - nobody holds a role on the `eth` entry, so `.eth` can never be repointed or
///   given a resolver.
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
  /// Roles the deployer holds on the `eth` entry.
  deployerEthEntryRoles: bigint;
  /// `ETHRegistry` root roles of the deployer.
  deployerEthRegistryRoles: bigint;
};

export type RegistryHandoverCall = {
  registry: "RootRegistry" | "ETHRegistry";
  functionName: "grantRootRoles" | "revokeRootRoles" | "revokeRoles";
  args: readonly [bigint, Address] | readonly [bigint, bigint, Address];
  label: string;
};

/// The calls that take the registries from `state` to the handed-over end state, in
/// order. The owner's grant comes before the deployer's revocation, so the root
/// registry never passes through a moment with no admin. Empty once handed over.
export function planRegistryHandover(
  state: RegistryHandoverState,
): RegistryHandoverCall[] {
  // Granting to and revoking from the same account would leave the root registry
  // with no admin at all, which no later transaction could repair.
  if (sameAddress(state.owner, state.deployer)) {
    throw new Error(
      `the owner ${state.owner} is the deployer: there is no one to hand the registries to`,
    );
  }

  const calls: RegistryHandoverCall[] = [];
  const missing = DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT & ~state.ownerRootRoles;
  if (missing !== 0n) {
    calls.push({
      registry: "RootRegistry",
      functionName: "grantRootRoles",
      args: [missing, state.owner],
      label: `grant the owner ${state.owner} the root registry's root roles`,
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
