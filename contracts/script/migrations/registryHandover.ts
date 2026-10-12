/// Hands the deployer's authority over the v2 registries to its final holders.
///
/// The deploy leaves the deployer holding root roles on `RootRegistry` and
/// `ETHRegistry`, and the `eth` token in the root. After the migration:
/// - the endowment (the ENS DAO endowment Safe on mainnet) holds the `eth` token,
///   and with it every role on the entry: setting its child registry and resolver,
///   granting either, and transferring the token;
/// - the owner (the DAO on mainnet) takes the root registry's root roles, admin
///   bits included, for a probation period before it drops them itself;
/// - the owner takes the `.eth` registry's root roles, so it can authorize
///   registrars and migration controllers. None of them reaches a name, so `.eth`
///   names stay emancipated.
///
/// This module plans the calls from the roles currently held, so a re-run sends only
/// what is missing. It knows nothing about signing or sending them.

import type { Address, Hex } from "viem";

import { DEPLOYMENT_ROLES } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// What the deployer, the owner and the endowment currently hold, as the plan reads it.
export type RegistryHandoverState = {
  deployer: Address;
  owner: Address;
  endowment: Address;
  /// Current token id of the `eth` entry in `RootRegistry`. A role change on the
  /// entry regenerates it, so it is read just before the plan runs.
  ethTokenId: bigint;
  /// Holder of the `eth` token.
  ethTokenHolder: Address;
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
  registry: "RootRegistry" | "ETHRegistry";
  functionName: "grantRootRoles" | "revokeRootRoles" | "safeTransferFrom";
  args:
    | readonly [bigint, Address]
    | readonly [Address, Address, bigint, bigint, Hex];
  label: string;
};

/// The calls that take the registries from `state` to the handed-over end state, in
/// order. The `eth` token moves first, while the deployer is still the only account
/// with a role on the entry, as a safe transfer requires; its roles move with it.
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
  if (sameAddress(state.endowment, state.deployer)) {
    throw new Error(
      `the endowment ${state.endowment} is the deployer: there is no one to hand the eth token to`,
    );
  }

  const calls: RegistryHandoverCall[] = [];
  if (sameAddress(state.ethTokenHolder, state.deployer)) {
    calls.push({
      registry: "RootRegistry",
      functionName: "safeTransferFrom",
      args: [state.deployer, state.endowment, state.ethTokenId, 1n, "0x"],
      label: `transfer the eth token, and every role on the entry, to the endowment ${state.endowment}`,
    });
  } else if (!sameAddress(state.ethTokenHolder, state.endowment)) {
    throw new Error(
      `the eth token is held by ${state.ethTokenHolder}, neither the deployer nor the endowment ${state.endowment}`,
    );
  }
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

/// The root registry root roles the owner keeps once the root is emancipated: the
/// regular naming and metadata roles it was granted at deploy, and the roles that
/// add top-level names and give reserved ones to their operators.
export const EMANCIPATED_OWNER_ROOT_ROLES =
  DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER |
  DEPLOYMENT_ROLES.ROOT_REGISTRY_TLD_ISSUER;

/// The root roles the owner drops to emancipate root names: everything it holds on
/// the root registry except the roles it keeps. Zero once emancipated.
export function rootEmancipationRoles(ownerRootRoles: bigint): bigint {
  return ownerRootRoles & ~EMANCIPATED_OWNER_ROOT_ROLES;
}
