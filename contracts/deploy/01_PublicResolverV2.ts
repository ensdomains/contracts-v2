import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("PublicResolverV2", {
      account: deployer,
      artifact: artifacts.PublicResolverV2,
      args: [nameWrapper.address, rootRegistry.address, contractNamer.address],
    });
  },
  {
    tags: ["PublicResolverV2", "v2"],
    dependencies: ["NameWrapper", "RootRegistry", "ContractNamer"],
  },
);
