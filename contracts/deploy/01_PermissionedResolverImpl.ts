import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    await deploy("PermissionedResolverImpl", {
      account: deployer,
      artifact: artifacts["PermissionedResolver"],
      args: [hcaFactory.address],
    });
  },
  {
    tags: ["PermissionedResolverImpl", "l1"],
    dependencies: ["HCAFactory"],
  },
);
