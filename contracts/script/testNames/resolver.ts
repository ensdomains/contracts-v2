import { type Address, namehash } from "viem";

import type { DevnetAccount, DevnetEnvironment } from "../setup.js";
import { trackGas } from "./gas.js";

/**
 * Deploy a resolver and set default records
 */
export async function setupResolver(
  env: DevnetEnvironment,
  account: DevnetAccount,
  name: string,
  records: {
    description?: string;
    address?: Address;
  },
  shouldTrackGas: boolean = false,
) {
  const { resolver } = account;
  const node = namehash(name);

  if (shouldTrackGas) {
    trackGas("deployResolver", resolver.deploymentReceipt);
  }

  // Set ETH address (coin type 60)
  if (records.address) {
    const receipt = await env.waitFor(
      resolver.write.setAddr([node, 60n, records.address]),
    );
    if (shouldTrackGas) trackGas(`setAddr(${name})`, receipt);
  }

  // Set description text record
  if (records.description) {
    const receipt = await env.waitFor(
      resolver.write.setText([node, "description", records.description]),
    );
    if (shouldTrackGas) trackGas(`setText(${name})`, receipt);
  }

  return resolver;
}
