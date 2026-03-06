import { type Address, namehash } from "viem";

import type { DevnetEnvironment } from "../setup.js";
import { trackGas } from "./gas.js";

/**
 * Deploy a resolver and set default records
 */
export async function deployResolverWithRecords(
  env: DevnetEnvironment,
  account: any,
  name: string,
  records: {
    description?: string;
    address?: Address;
  },
  shouldTrackGas: boolean = false,
) {
  const resolver = await env.deployment.deployPermissionedResolver({ account });
  const node = namehash(name);

  if (shouldTrackGas) {
    await trackGas("deployResolver", resolver.deploymentReceipt);
  }

  // Set ETH address (coin type 60)
  if (records.address) {
    const { receipt } = await env.waitFor(
      resolver.write.setAddr([node, 60n, records.address], { account }),
    );
    if (shouldTrackGas) await trackGas(`setAddr(${name})`, receipt);
  }

  // Set description text record
  if (records.description) {
    const { receipt } = await env.waitFor(
      resolver.write.setText([node, "description", records.description], {
        account,
      }),
    );
    if (shouldTrackGas) await trackGas(`setText(${name})`, receipt);
  }

  return resolver;
}
