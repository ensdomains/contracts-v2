import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("PublicResolverV2", {
      account: deployer,
      artifact: artifacts.PublicResolverV2,
      args: [
        hcaFactory.address,
        nameWrapper.address,
        rootRegistry.address,
        contractNamer.address,
      ],
    });
  },
  {
    tags: ["PublicResolverV2", "v2"],
    dependencies: [
      "NameWrapper",
      "HCAFactory",
      "RootRegistry",
      "ContractNamer",
    ],
  },
);
