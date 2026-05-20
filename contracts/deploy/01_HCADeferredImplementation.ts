import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>(
      "HCAFactory",
    );

    await deploy("HCADeferredImplementation", {
      account: deployer,
      artifact: artifacts.HCADeferredImplementation,
      args: [hcaFactory.address],
    });
  },
  {
    tags: ["HCADeferredImplementation", "v2"],
    dependencies: ["HCAFactory"],
  },
);
