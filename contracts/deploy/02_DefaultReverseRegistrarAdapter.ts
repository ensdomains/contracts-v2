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
      // The v1 DefaultReverseRegistrar is owned by the v1 owner, not the v2
      // admin, so route the controller grant through v1Owner (honouring the
      // deferred v1-owner transaction flow, which only captures v1Owner sends).
      await write(defaultReverseRegistrar, {
        account: v1Owner ?? owner,
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
