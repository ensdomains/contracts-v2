import { artifacts, execute } from "@rocketh";

import {
  controllerAddressHistory,
  replacedDeploymentAddresses,
  SUPERSEDED_CONTROLLER_ADDRESSES,
} from "./hca/_helpers.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getOrNull,
    getV1,
    read,
    namedAccounts: { deployer, owner, v1Owner },
  }) => {
    const defaultReverseRegistrar = await getV1<
      (typeof artifacts.DefaultReverseRegistrar)["abi"]
    >("DefaultReverseRegistrar");

    const standaloneHCAFactory = get<
      (typeof artifacts.StandaloneHCAFactory)["abi"]
    >("StandaloneHCAFactory");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const previousAdapter = getOrNull("DefaultReverseRegistrarAdapter");
    const legacyHCAAdapter = getOrNull("DefaultReverseRegistrarHCAAdapter");
    const priorControllers = [previousAdapter, legacyHCAAdapter];
    const adapter = await deploy(
      "DefaultReverseRegistrarAdapter",
      {
        account: deployer,
        artifact: artifacts.DefaultReverseRegistrarAdapter,
        args: [
          defaultReverseRegistrar.address,
          standaloneHCAFactory.address,
          contractNamer.address,
        ],
      },
      {
        linkedData: {
          [SUPERSEDED_CONTROLLER_ADDRESSES]:
            controllerAddressHistory(priorControllers),
        },
      },
    );

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

    for (const previousAddress of replacedDeploymentAddresses(
      adapter,
      priorControllers,
    )) {
      const previousIsController = await read(defaultReverseRegistrar, {
        functionName: "controllers",
        args: [previousAddress],
      });
      if (previousIsController) {
        await write(defaultReverseRegistrar, {
          account: v1Owner ?? owner,
          functionName: "setController",
          args: [previousAddress, false],
        });
      }
    }
  },
  {
    tags: [
      "DefaultReverseRegistrarAdapter",
      "migration:phase1:deploy-v2",
      "v2",
      "hca",
    ],
    dependencies: ["ContractNamer", "StandaloneHCAFactory"],
  },
);
