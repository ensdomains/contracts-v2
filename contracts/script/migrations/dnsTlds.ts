/// Repointing the root registry's reserved DNS top-level names at a new resolver.
///
/// A reservation has no owner and so no roles, and no account may set resolvers
/// registry-wide, so a reserved name's resolver cannot be changed in place. The
/// `ReservedNameResolverUpdater` contract moves each name in one call instead: it
/// registers the reservation to itself with only the role to unregister it,
/// unregisters it, and reserves it again with the new resolver and the same expiry.
/// A name is never left unreserved between transactions, so each one is either still
/// on its old resolver or already on the new one, and a stopped run resumes with the
/// names still on the old one.

import type { Address } from "viem";

import { STATUS } from "../deploy-constants.js";
import { sameAddress } from "./plumbing.js";

/// What the root registry reports for one top-level name.
export type TldState = {
  status: number;
  resolver: Address;
};

export type TldPlan =
  | { kind: "done" }
  | { kind: "move" }
  | { kind: "blocked"; reason: string };

/// Whether a top-level name is already reserved with `resolver`, still needs moving,
/// or cannot be moved, since only a reserved name can be.
export function planTld(state: TldState, resolver: Address): TldPlan {
  if (state.status !== STATUS.RESERVED) {
    return {
      kind: "blocked",
      reason:
        state.status === STATUS.REGISTERED
          ? "registered, not reserved"
          : state.status === STATUS.AVAILABLE
            ? "available, not reserved"
            : `unknown status ${state.status}`,
    };
  }
  return sameAddress(state.resolver, resolver)
    ? { kind: "done" }
    : { kind: "move" };
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
