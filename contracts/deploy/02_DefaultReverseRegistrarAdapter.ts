import { artifacts, execute } from "@rocketh";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    read,
    namedAccounts: { deployer, owner },
    network,
  }) => {
    const defaultReverseRegistrar = get<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const adapter = await deploy("DefaultReverseRegistrarAdapter", {
      account: deployer,
      artifact: artifacts.DefaultReverseRegistrarAdapter,
      args: [
        defaultReverseRegistrar.address,
        contractNamer.address,
        verifiableFactory.address,
        owner,
        [],
      ],
    });

    if (network.name === "mainnet" && !network.tags?.tenderly) return;

    const adapterIsDefaultController = await read(defaultReverseRegistrar, {
      functionName: "controllers",
      args: [adapter.address],
    });

    if (!adapterIsDefaultController) {
      await write(defaultReverseRegistrar, {
        account: owner,
        functionName: "setController",
        args: [adapter.address, true],
      });
    }
  },
  {
    tags: ["DefaultReverseRegistrarAdapter", "v2"],
    dependencies: [
      "DefaultReverseRegistrar",
      "ContractNamer",
      "VerifiableFactory",
    ],
  },
);
