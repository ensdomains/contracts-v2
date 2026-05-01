import { artifacts, execute } from "@rocketh";

import { encodeTemplateInitData } from "./_helpers.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");
    const entryPoint = get<(typeof artifacts.EntryPoint)["abi"]>("EntryPoint");
    const hcaModule = get<(typeof artifacts.HCAModule)["abi"]>("HCAModule");
    const intentExecutor =
      get<(typeof artifacts.IntentExecutor)["abi"]>("IntentExecutor");

    await deploy("HCAImplementation", {
      account: deployer,
      artifact: artifacts.HCA,
      args: [
        hcaFactory.address,
        entryPoint.address,
        hcaModule.address,
        intentExecutor.address,
        encodeTemplateInitData(),
      ],
    });
  },
  {
    tags: ["HCAImplementation", "v2"],
    dependencies: [
      "HCAFactoryBase",
      "HCAEntryPoint",
      "HCAModule",
      "IntentExecutor",
    ],
  },
);
