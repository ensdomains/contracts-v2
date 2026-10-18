import { describe, expect, it } from "bun:test";
import { zeroAddress } from "viem";

import { STATUS } from "../../script/deploy-constants.js";
import { firstReservations, planTld } from "../../script/migrations/dnsTlds.js";

const resolver = "0x00000000000000000000000000000000000000bb" as const;
const oldResolver = "0x00000000000000000000000000000000000000cc" as const;

describe("planTld", () => {
  it("leaves a name reserved with the resolver alone", () => {
    expect(planTld({ status: STATUS.RESERVED, resolver }, resolver)).toEqual({
      kind: "done",
    });
  });

  it("moves a name reserved with another resolver", () => {
    expect(
      planTld({ status: STATUS.RESERVED, resolver: oldResolver }, resolver),
    ).toEqual({ kind: "move" });
  });

  it("refuses a name that is registered or available", () => {
    expect(
      planTld({ status: STATUS.REGISTERED, resolver: oldResolver }, resolver),
    ).toEqual({ kind: "blocked", reason: "registered, not reserved" });
    expect(
      planTld({ status: STATUS.AVAILABLE, resolver: zeroAddress }, resolver),
    ).toEqual({ kind: "blocked", reason: "available, not reserved" });
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
