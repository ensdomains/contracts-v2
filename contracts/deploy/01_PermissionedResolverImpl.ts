import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.IHCAFactoryBasic)["abi"]>("HCAFactory");

    await deploy("PermissionedResolverImpl", {
      account: deployer,
      artifact: artifacts["PermissionedResolver"],
      args: [hcaFactory.address],
    });
  },
  {
    tags: ["PermissionedResolverImpl", "v2"],
    dependencies: ["HCAFactory"],
  },
);
