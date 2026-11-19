import { describe, it } from "vitest";
import type { Address } from "viem";
import { forkAndAttach } from "./forkedFixture.js";

const { connection, forkedFixture } = await forkAndAttach();

describe("forkedFixture", () => {
  it("deployments", async () => {
    const F = await connection.networkHelpers.loadFixture(forkedFixture);
    console.table(findAddresses(F));
  });
});

function findAddresses(
  obj: Record<string, any>,
  found: { name: string; address: Address }[] = [],
  path: string[] = [],
) {
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v !== "object") continue;
    const { address } = v;
    if (address?.startsWith("0x")) {
      found.push({ name: [...path, k].join("/"), address });
    } else {
      findAddresses(v, found, [...path, k]);
    }
  }
  return found;
}
