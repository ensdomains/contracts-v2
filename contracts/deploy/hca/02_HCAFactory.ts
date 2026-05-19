import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";

import { resolveFactoryOwner } from "./_helpers.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const hcaModule = get<(typeof artifacts.HCAModule)["abi"]>("HCAModule");

    await deploy("HCAFactory", {
      account: deployer,
      artifact: artifacts.HCAFactory,
      args: [
        zeroAddress,
        hcaModule.address,
        resolveFactoryOwner(deployer, owner),
      ],
    });
  },
  {
    tags: ["HCAFactoryBase", "v2"],
    dependencies: ["HCAModule"],
  },
);
