/// Hands the deployer's authority over the v2 registries to its final holders.
///
/// The deploy leaves the deployer holding root roles on `RootRegistry` and
/// `ETHRegistry`, the `eth` token in the root, and ownership of the two batch
/// registrars. After the migration:
/// - the endowment (the ENS DAO endowment Safe on mainnet) holds the `eth` token,
///   and with it every role on the entry: setting its child registry and resolver,
///   granting either, and transferring the token;
/// - the endowment holds `on.eth`, which the deployer registers for it with every
///   role and admin role and the expiry it has on v1, where v1 holds it live;
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

import { DEPLOYMENT_ROLES, ROLES, STATUS } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// The `.eth` name the deployer registers for the endowment at the handover.
export const ON_ETH_LABEL = "on";

/// The contracts the handover writes to.
export type HandoverContract =
  | "RootRegistry"
  | "ETHRegistry"
  | "BatchRegistrar"
  | "RootBatchRegistrar";

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
  /// Status of `on.eth` in `ETHRegistry`, its current token id, and its holder.
  onStatus: number;
  /// Expiry of `on.eth` on v1, and the chain's current time.
  onV1Expiry: bigint;
  chainNow: bigint;
  onTokenId: bigint;
  onTokenHolder: Address;
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
    | "register"
    | "renounceOwnership";
  args:
    | readonly []
    | readonly [bigint, Address]
    | readonly [Address, Address, bigint, bigint, Hex]
    | readonly [string, Address, Address, Address, bigint, bigint];
  label: string;
};

/// Whether the handover carries `on.eth`: once registered on v2, or while v1 holds
/// it live, which gives the expiry to register it with.
export function handsOverOnEth(
  state: Pick<RegistryHandoverState, "onStatus" | "onV1Expiry" | "chainNow">,
): boolean {
  return (
    state.onStatus === STATUS.REGISTERED || state.onV1Expiry > state.chainNow
  );
}

/// The calls that register `on.eth` to the deployer with every role and admin role
/// and its v1 expiry, for the handover to pass to the endowment: the `.eth` registry
/// role its status needs, which the deployer grants itself and drops with its other
/// roles at the end, then the registration. Empty once `on.eth` is registered, or
/// where v1 holds no live `on.eth` to match.
export function planOnEthRegistration(
  state: Pick<
    RegistryHandoverState,
    | "deployer"
    | "onStatus"
    | "onV1Expiry"
    | "chainNow"
    | "deployerEthRegistryRoles"
  >,
): RegistryHandoverCall[] {
  if (state.onStatus === STATUS.REGISTERED || !handsOverOnEth(state)) {
    return [];
  }
  const role =
    state.onStatus === STATUS.RESERVED
      ? ROLES.REGISTRY.REGISTER_RESERVED
      : ROLES.REGISTRY.REGISTRAR;
  const calls: RegistryHandoverCall[] = [];
  if ((state.deployerEthRegistryRoles & role) === 0n) {
    calls.push({
      contract: "ETHRegistry",
      functionName: "grantRootRoles",
      args: [role, state.deployer],
      label: `let the deployer register ${state.onStatus === STATUS.RESERVED ? "the reserved" : "the available"} on.eth`,
    });
  }
  calls.push({
    contract: "ETHRegistry",
    functionName: "register",
    args: [
      ON_ETH_LABEL,
      state.deployer,
      zeroAddress,
      zeroAddress,
      DEPLOYMENT_ROLES.ON_ETH_TOKEN,
      state.onV1Expiry,
    ],
    label: "register on.eth to the deployer with every role and admin role",
  });
  return calls;
}

/// The calls that take the registries from `state` to the handed-over end state, in
/// order, once `on.eth` is registered. The `eth` and `on.eth` tokens move first,
/// while the deployer is still the only account with a role on either, as a safe
/// transfer requires; their roles move with them.
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
      contract: "RootRegistry",
      functionName: "safeTransferFrom",
      args: [state.deployer, state.endowment, state.ethTokenId, 1n, "0x"],
      label: `transfer the eth token, and every role on the entry, to the endowment ${state.endowment}`,
    });
  } else if (!sameAddress(state.ethTokenHolder, state.endowment)) {
    throw new Error(
      `the eth token is held by ${state.ethTokenHolder}, neither the deployer nor the endowment ${state.endowment}`,
    );
  }
  if (handsOverOnEth(state)) {
    if (state.onStatus !== STATUS.REGISTERED) {
      throw new Error(
        "on.eth is not registered yet: register it before planning the rest",
      );
    }
    if (sameAddress(state.onTokenHolder, state.deployer)) {
      calls.push({
        contract: "ETHRegistry",
        functionName: "safeTransferFrom",
        args: [state.deployer, state.endowment, state.onTokenId, 1n, "0x"],
        label: `transfer on.eth, and every role on it, to the endowment ${state.endowment}`,
      });
    } else if (!sameAddress(state.onTokenHolder, state.endowment)) {
      throw new Error(
        `on.eth is held by ${state.onTokenHolder}, neither the deployer nor the endowment ${state.endowment}`,
      );
    }
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
