import { artifacts, execute } from "@rocketh";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer, owner },
    name,
    tags,
  }) => {
    const defaultReverseRegistrar = await getV1<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const adapter = await deploy("DefaultReverseRegistrarAdapter", {
      account: deployer,
      artifact: artifacts.DefaultReverseRegistrarAdapter,
      args: [defaultReverseRegistrar.address, contractNamer.address],
    });

    if (name === "mainnet" && !tags.tenderly) {
      return;
    }

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
    dependencies: ["ContractNamer"],
  },
);
