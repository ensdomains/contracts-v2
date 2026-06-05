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
    const reverseRegistrar =
      get<(typeof artifacts.ReverseRegistrar)["abi"]>("ReverseRegistrar");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const adapter = await deploy("ReverseRegistrarAdapter", {
      account: deployer,
      artifact: artifacts.ReverseRegistrarAdapter,
      args: [
        reverseRegistrar.address,
        contractNamer.address,
        verifiableFactory.address,
        owner,
        [],
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
    tags: ["ReverseRegistrarAdapter", "v2"],
    dependencies: ["ReverseRegistrar", "ContractNamer", "VerifiableFactory"],
  },
);
