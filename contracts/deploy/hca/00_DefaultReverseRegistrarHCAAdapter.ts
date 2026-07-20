import { artifacts, execute } from "@rocketh";
import { getAddress } from "viem";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getOrNull,
    getV1,
    namedAccounts: { deployer, owner, v1Owner },
    read,
    tags,
  }) => {
    if (!tags.hca || !tags.sepolia || tags.dev || tags.local || tags.test)
      return;

    const defaultReverseRegistrar = await getV1<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");
    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");
    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");
    const existingAdapter = getOrNull<
      (typeof artifacts.DefaultReverseRegistrarAdapter)["abi"]
    >("DefaultReverseRegistrarHCAAdapter");
    const replaceExisting = existingAdapter
      ? getAddress(
          await read(existingAdapter, {
            functionName: "owner",
          }),
        ) !== getAddress(owner)
      : false;
    const replacedAdapterAddress = replaceExisting
      ? existingAdapter?.address
      : undefined;

    const adapter = await deploy(
      "DefaultReverseRegistrarHCAAdapter",
      {
        account: deployer,
        artifact: artifacts.DefaultReverseRegistrarAdapter,
        args: [
          defaultReverseRegistrar.address,
          contractNamer.address,
          verifiableFactory.address,
          owner,
          [],
        ],
      },
      replaceExisting ? { alwaysOverride: true } : undefined,
    );

    const isController = await read(defaultReverseRegistrar, {
      functionName: "controllers",
      args: [adapter.address],
    });
    if (!isController) {
      await write(defaultReverseRegistrar, {
        account: v1Owner ?? owner,
        functionName: "setController",
        args: [adapter.address, true],
      });
    }
    if (replacedAdapterAddress) {
      const oldIsController = await read(defaultReverseRegistrar, {
        functionName: "controllers",
        args: [replacedAdapterAddress],
      });
      if (oldIsController) {
        await write(defaultReverseRegistrar, {
          account: v1Owner ?? owner,
          functionName: "setController",
          args: [replacedAdapterAddress, false],
        });
      }
    }
  },
  {
    tags: ["DefaultReverseRegistrarHCAAdapter", "StandaloneHCA", "hca"],
    dependencies: ["ContractNamer", "VerifiableFactory"],
  },
);
