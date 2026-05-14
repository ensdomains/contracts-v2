import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    await deploy("PermissionedResolverImpl", {
      account: deployer,
      artifact: artifacts["PermissionedResolver"],
      args: [hcaFactory.address, owner],
    });
  },
  {
    tags: ["PermissionedResolverImpl", "v2"],
    dependencies: ["HCAFactory"],
  },
);
