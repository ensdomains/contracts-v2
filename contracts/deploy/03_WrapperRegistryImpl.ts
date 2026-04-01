import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    await deploy("WrapperRegistryImpl", {
      account: deployer,
      artifact: artifacts.WrapperRegistry,
      args: [
        nameWrapper.address,
        verifiableFactory.address,
        ensV1Resolver.address,
        hcaFactory.address,
        registryMetadata.address,
        labelStore.address,
      ],
    });
  },
  {
    tags: ["WrapperRegistryImpl", "v2"],
    dependencies: [
      "NameWrapper",
      "VerifiableFactory",
      "ENSV1Resolver",
      "HCAFactory",
      "RegistryMetadata",
      "LabelStore",
    ],
  },
);
