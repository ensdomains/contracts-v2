import { describe, expect, it } from "bun:test";
import { zeroAddress } from "viem";

import { STATUS } from "../../script/deploy-constants.js";
import {
  firstReservations,
  nextTldStep,
  type TldState,
} from "../../script/migrations/dnsTlds.js";

const sender = "0x00000000000000000000000000000000000000aa" as const;
const resolver = "0x00000000000000000000000000000000000000bb" as const;
const oldResolver = "0x00000000000000000000000000000000000000cc" as const;

const state = (overrides: Partial<TldState>): TldState => ({
  status: STATUS.RESERVED,
  owner: zeroAddress,
  resolver: oldResolver,
  senderCanUnregister: false,
  ...overrides,
});

describe("nextTldStep", () => {
  it("leaves a name reserved with the resolver alone", () => {
    expect(nextTldStep(state({ resolver }), resolver, sender)).toEqual({
      kind: "done",
    });
  });

  it("walks a name through register, unregister and reserve", () => {
    expect(nextTldStep(state({}), resolver, sender).kind).toBe("register");
    expect(
      nextTldStep(
        state({
          status: STATUS.REGISTERED,
          owner: sender,
          senderCanUnregister: true,
        }),
        resolver,
        sender,
      ).kind,
    ).toBe("unregister");
    expect(
      nextTldStep(
        state({ status: STATUS.AVAILABLE, resolver: zeroAddress }),
        resolver,
        sender,
      ).kind,
    ).toBe("reserve");
  });

  it("refuses a name registered to someone else or that the sender may not unregister", () => {
    expect(
      nextTldStep(
        state({ status: STATUS.REGISTERED, owner: resolver }),
        resolver,
        sender,
      ).kind,
    ).toBe("blocked");
    expect(
      nextTldStep(
        state({ status: STATUS.REGISTERED, owner: sender }),
        resolver,
        sender,
      ).kind,
    ).toBe("blocked");
  });
});

describe("firstReservations", () => {
  it("keeps each label's first expiry in first-reserved order", () => {
    const expiries = firstReservations([
      { label: "com", expiry: 5n },
      { label: "xyz", expiry: 7n },
      { label: "com", expiry: 9n },
    ]);
    expect([...expiries]).toEqual([
      ["com", 5n],
      ["xyz", 7n],
    ]);
  });
});
