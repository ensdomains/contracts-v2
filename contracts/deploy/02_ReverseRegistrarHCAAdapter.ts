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
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");

    const reverseRegistrar =
      get<(typeof artifacts.ReverseRegistrar)["abi"]>("ReverseRegistrar");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const adapter = await deploy("ReverseRegistrarHCAAdapter", {
      account: deployer,
      artifact: artifacts.ReverseRegistrarHCAAdapter,
      args: [
        hcaFactory.address,
        reverseRegistrar.address,
        contractNamer.address,
      ],
    });

    if (network.name === "mainnet" && !network.tags?.tenderly) return;

    const adapterIsReverseController = await read(reverseRegistrar, {
      functionName: "controllers",
      args: [adapter.address],
    });

    if (!adapterIsReverseController) {
      await write(reverseRegistrar, {
        account: owner,
        functionName: "setController",
        args: [adapter.address, true],
      });
    }
  },
  {
    tags: ["ReverseRegistrarHCAAdapter", "v2"],
    dependencies: ["HCAFactory", "ReverseRegistrar", "ContractNamer"],
  },
);
