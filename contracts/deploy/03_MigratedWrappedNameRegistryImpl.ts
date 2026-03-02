import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const nameWrapperV1 =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const registryMetadata = get<
      (typeof artifacts.SimpleRegistryMetadata)["abi"]
    >("SimpleRegistryMetadata");

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    await deploy("MigratedWrappedNameRegistryImpl", {
      account: deployer,
      artifact: artifacts.MigratedWrappedNameRegistry,
      args: [
        nameWrapperV1.address,
        ethRegistry.address,
        verifiableFactory.address,
        hcaFactory.address,
        registryMetadata.address,
        ensV1Resolver.address,
      ],
    });
  },
  {
    tags: ["MigratedWrappedNameRegistryImpl", "l1"],
    dependencies: [
      "NameWrapper",
      "HCAFactory",
      "ETHRegistry",
      "VerifiableFactory",
      "ENSV1Resolver",
    ],
  },
);
