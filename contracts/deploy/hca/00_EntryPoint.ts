import { artifacts, execute } from "@rocketh";
import { isAddressEqual, type Address } from "viem";

import {
  DEFAULT_ENTRY_POINT,
  ENTRY_POINT_V07_ARTIFACT,
  hasCode,
} from "./_helpers.js";
import { ENTRY_POINT_V07_SALT } from "./_entrypoint070.js";

export default execute(
  async ({ deploy, network, save, namedAccounts: { deployer } }) => {
    const entryPointAddress = DEFAULT_ENTRY_POINT as Address;
    if (await hasCode(network.provider, entryPointAddress)) {
      await save(
        "EntryPoint",
        {
          ...artifacts.EntryPoint,
          address: entryPointAddress,
          argsData: "0x",
          bytecode: "0x",
          deployedBytecode: "0x",
          metadata: "{}",
        },
        { doNotCountAsNewDeployment: true },
      );
      return;
    }

    const entryPoint = await deploy(
      "EntryPoint",
      {
        account: deployer,
        artifact: ENTRY_POINT_V07_ARTIFACT,
        args: [],
      },
      { deterministic: { type: "create2", salt: ENTRY_POINT_V07_SALT } },
    );

    if (!isAddressEqual(entryPoint.address, entryPointAddress)) {
      throw new Error(
        `EntryPoint v0.7 deployed to ${entryPoint.address}, expected ${entryPointAddress}`,
      );
    }
  },
  {
    tags: ["EntryPoint", "HCAEntryPoint", "v2"],
  },
);
