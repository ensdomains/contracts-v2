/// Hands the deployer's authority over the v2 registries to its final holders.
///
/// The deploy leaves the deployer holding root roles on `RootRegistry` and
/// `ETHRegistry`, the `eth` token in the root, and ownership of the two batch
/// registrars. After the migration:
/// - the name owner (the ENS DAO name owner Safe on mainnet) holds the `eth` token,
///   and with it every role on the entry: setting its child registry and resolver,
///   granting either, and transferring the token;
/// - the owner (the DAO on mainnet) takes the root registry's root roles, admin
///   bits included, for a probation period before it drops them itself;
/// - the owner takes the `.eth` registry's root roles, so it can authorize
///   registrars and migration controllers. None of them reaches a name, so `.eth`
///   names stay emancipated;
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

/// What the deployer, the owner and the name owner currently hold, as the plan reads it.
export type RegistryHandoverState = {
  deployer: Address;
  owner: Address;
  nameOwner: Address;
  /// Current token id of the `eth` entry in `RootRegistry`. A role change on the
  /// entry regenerates it, so it is read just before the plan runs.
  ethTokenId: bigint;
  /// Holder of the `eth` token.
  ethTokenHolder: Address;
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
  if (sameAddress(state.nameOwner, state.deployer)) {
    throw new Error(
      `the name owner ${state.nameOwner} is the deployer: there is no one to hand the eth token to`,
    );
  }

  const calls: RegistryHandoverCall[] = [];
  if (sameAddress(state.ethTokenHolder, state.deployer)) {
    calls.push({
      contract: "RootRegistry",
      functionName: "safeTransferFrom",
      args: [state.deployer, state.nameOwner, state.ethTokenId, 1n, "0x"],
      label: `transfer the eth token, and every role on the entry, to the name owner ${state.nameOwner}`,
    });
  } else if (!sameAddress(state.ethTokenHolder, state.nameOwner)) {
    throw new Error(
      `the eth token is held by ${state.ethTokenHolder}, neither the deployer nor the name owner ${state.nameOwner}`,
    );
  }
  const missingRoot =
    DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT & ~state.ownerRootRoles;
  if (missingRoot !== 0n) {
    calls.push({
      contract: "RootRegistry",
      functionName: "grantRootRoles",
      args: [missingRoot, state.owner],
      label: `grant the owner ${state.owner} the root registry's root roles`,
    });
  }
  const missingEthRegistry =
    DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT & ~state.ownerEthRegistryRoles;
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
