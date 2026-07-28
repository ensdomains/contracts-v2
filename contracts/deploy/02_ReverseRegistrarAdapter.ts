import { artifacts, execute } from "@rocketh";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer, owner, v1Owner },
  }) => {
    const reverseRegistrar =
      await getV1<(typeof artifacts.ReverseRegistrar)["abi"]>(
        "ReverseRegistrar",
      );

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const trustedHCASet =
      get<(typeof artifacts.PermissionedAddressSet)["abi"]>("TrustedHCASet");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const adapter = await deploy("ReverseRegistrarAdapter", {
      account: deployer,
      artifact: artifacts.ReverseRegistrarAdapter,
      args: [
        reverseRegistrar.address,
        verifiableFactory.address,
        trustedHCASet.address,
        contractNamer.address,
      ],
    });

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
    tags: ["ReverseRegistrarAdapter", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["ContractNamer", "VerifiableFactory", "TrustedHCASet"],
  },
);
