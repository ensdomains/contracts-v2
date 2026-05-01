import { artifacts, execute } from "@rocketh";

import { resolveFactoryOwner } from "./_helpers.js";

export default execute(
  async ({ execute: write, get, namedAccounts: { deployer, owner } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");
    const hcaImplementation =
      get<(typeof artifacts.HCA)["abi"]>("HCAImplementation");
    const hcaModule = get<(typeof artifacts.HCAModule)["abi"]>("HCAModule");

    await write(hcaFactory, {
      account: resolveFactoryOwner(deployer, owner),
      functionName: "setImplementation",
      args: [hcaImplementation.address, hcaModule.address],
    });
  },
  {
    tags: ["HCAFactory", "v2"],
    dependencies: ["HCAFactoryBase", "HCAImplementation", "HCAModule"],
  },
);
