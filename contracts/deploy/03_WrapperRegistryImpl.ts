import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, getV1, namedAccounts: { deployer, owner } }) => {
    const nameWrapper =
      await getV1<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const graveyard = get<(typeof artifacts.Graveyard)["abi"]>("Graveyard");

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    const registryUpgradeSet =
      get<(typeof artifacts.IAddressSet)["abi"]>("RegistryUpgradeSet");

    const publicResolverSet =
      get<(typeof artifacts.IAddressSet)["abi"]>("PublicResolverSet");

    const publicResolverV2 =
      get<(typeof artifacts.PublicResolverV2)["abi"]>("PublicResolverV2");

    await deploy("WrapperRegistryImpl", {
      account: deployer,
      artifact: artifacts.WrapperRegistry,
      args: [
        nameWrapper.address,
        graveyard.address,
        verifiableFactory.address,
        ensV1Resolver.address,
        registryUpgradeSet.address,
        labelStore.address,
        publicResolverSet.address,
        publicResolverV2.address,
        owner,
      ],
    });
  },
  {
    tags: ["WrapperRegistryImpl", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "NameWrapper",
      "Graveyard",
      "VerifiableFactory",
      "ENSV1Resolver",
      "RegistryUpgradeSet",
      "LabelStore",
      "PublicResolverSet",
      "PublicResolverV2",
    ],
  },
);
