import { artifacts, execute } from "@rocketh";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer, owner, v1Owner },
    name,
    tags,
  }) => {
    const reverseRegistrar =
      await getV1<(typeof artifacts.ReverseRegistrar)["abi"]>(
        "ReverseRegistrar",
      );

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const adapter = await deploy("ReverseRegistrarAdapter", {
      account: deployer,
      artifact: artifacts.ReverseRegistrarAdapter,
      args: [reverseRegistrar.address, contractNamer.address],
    });

    if (name === "mainnet" && !tags.tenderly) {
      return;
    }

    const adapterIsReverseController = await read(reverseRegistrar, {
      functionName: "controllers",
      args: [adapter.address],
    });

    if (!adapterIsReverseController) {
      // The v1 ReverseRegistrar is owned by the v1 owner, not the v2 admin, so
      // route the controller grant through v1Owner (honouring the deferred
      // v1-owner transaction flow, which only captures v1Owner sends).
      await write(reverseRegistrar, {
        account: v1Owner ?? owner,
        functionName: "setController",
        args: [adapter.address, true],
      });
    }
  },
  {
    tags: ["ReverseRegistrarAdapter", "v2"],
    dependencies: ["ContractNamer"],
  },
);
