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
    const hcaFactory =
      get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");

    const defaultReverseRegistrar = get<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const adapter = await deploy("DefaultReverseRegistrarHCAAdapter", {
      account: deployer,
      artifact: artifacts.DefaultReverseRegistrarHCAAdapter,
      args: [hcaFactory.address, defaultReverseRegistrar.address],
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
    tags: ["DefaultReverseRegistrarHCAAdapter", "v2"],
    dependencies: ["HCAFactory", "DefaultReverseRegistrar"],
  },
);
