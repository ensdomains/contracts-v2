import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    await deploy("LabelStore", {
      account: deployer,
      artifact: artifacts.LabelStore,
      args: [rootRegistry.address],
    });
  },
  {
    tags: ["LabelStore", "v2"],
    dependencies: ["RootRegistry"],
  },
);
