/// Repointing the root registry's reserved DNS top-level names at a new resolver.
///
/// A reservation has no owner and so no roles, and no account may set resolvers
/// registry-wide, so a reserved name's resolver cannot be changed in place. An account
/// allowed to register reserved names and to register available ones can still move
/// it: register the reservation to itself with only the role to unregister and the
/// reservation's expiry, unregister it, and reserve it again with the new resolver and
/// the original expiry. Unregistering bumps the name's resource, so the role taken in
/// the first step stops reaching the name. The step each name needs next follows from
/// its state alone, so a stopped run resumes where it left off.

import type { Address } from "viem";

import { STATUS } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// What the root registry reports for one top-level name.
export type TldState = {
  status: number;
  // The current owner when registered.
  owner: Address;
  resolver: Address;
  // Whether the sender may unregister the name, read only when it is registered.
  senderCanUnregister: boolean;
};

export type TldStep =
  | { kind: "done" }
  | { kind: "register" }
  | { kind: "unregister" }
  | { kind: "reserve" }
  | { kind: "blocked"; reason: string };

/// The next transaction a top-level name needs before it is reserved with `resolver`
/// by `sender`, or why it cannot be moved.
export function nextTldStep(
  state: TldState,
  resolver: Address,
  sender: Address,
): TldStep {
  switch (state.status) {
    case STATUS.RESERVED:
      return sameAddress(state.resolver, resolver)
        ? { kind: "done" }
        : { kind: "register" };
    case STATUS.AVAILABLE:
      return { kind: "reserve" };
    case STATUS.REGISTERED:
      if (!sameAddress(state.owner, sender)) {
        return {
          kind: "blocked",
          reason: `registered to ${state.owner}, not the sender`,
        };
      }
      return state.senderCanUnregister
        ? { kind: "unregister" }
        : {
            kind: "blocked",
            reason: "registered to the sender, who may not unregister it",
          };
    default:
      return { kind: "blocked", reason: `unknown status ${state.status}` };
  }
}

/// Each label's expiry from its first reservation, in the order the labels were first
/// reserved. A later reservation of the same label, such as the one this move makes,
/// keeps the original.
export function firstReservations(
  logs: ReadonlyArray<{ label: string; expiry: bigint }>,
): Map<string, bigint> {
  const expiries = new Map<string, bigint>();
  for (const { label, expiry } of logs) {
    if (!expiries.has(label)) expiries.set(label, expiry);
  }
  return expiries;
}
