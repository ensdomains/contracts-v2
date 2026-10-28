/// Registering a network's directly registered names on v2.
///
/// A name in `DIRECT_REGISTRATIONS` is registered straight to its owner, outside
/// pre-migration, with every role and admin role. This module judges each name
/// against the registry; it knows nothing about reading the chain or sending.

import type { Address } from "viem";

import { ROLES, STATUS } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// A table entry with its resolver and expiry fixed, `"v1"` values read from v1.
export type ResolvedDirectRegistration = {
  label: string;
  owner: Address;
  resolver: Address;
  expiry: bigint;
};

/// The name's entry in the `.eth` registry, as the judgement reads it.
export type DirectRegistrationState = {
  status: number;
  latestOwner: Address;
  resolver: Address;
  expiry: bigint;
};

export type DirectRegistrationStanding =
  | { kind: "registered" }
  /// Not yet registered; registering needs this `.eth` registry root role.
  | { kind: "pending"; role: bigint }
  | { kind: "conflict"; reason: string };

/// How a name stands against its table entry: registered to its owner with its
/// resolver and expiry, free to register, or held some other way.
export function directRegistrationStanding(
  entry: ResolvedDirectRegistration,
  state: DirectRegistrationState,
): DirectRegistrationStanding {
  if (state.status === STATUS.REGISTERED) {
    const differences = [
      sameAddress(state.latestOwner, entry.owner)
        ? undefined
        : `owner ${state.latestOwner}, not ${entry.owner}`,
      sameAddress(state.resolver, entry.resolver)
        ? undefined
        : `resolver ${state.resolver}, not ${entry.resolver}`,
      state.expiry === entry.expiry
        ? undefined
        : `expiry ${state.expiry}, not ${entry.expiry}`,
    ].filter((difference): difference is string => difference !== undefined);
    return differences.length === 0
      ? { kind: "registered" }
      : {
          kind: "conflict",
          reason: `${entry.label}.eth is registered with ${differences.join(", ")}`,
        };
  }
  return {
    kind: "pending",
    role:
      state.status === STATUS.RESERVED
        ? ROLES.REGISTRY.REGISTER_RESERVED
        : ROLES.REGISTRY.REGISTRAR,
  };
}
