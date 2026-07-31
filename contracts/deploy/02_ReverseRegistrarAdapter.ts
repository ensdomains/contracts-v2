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
    const reverseRegistrar =
      await getV1<(typeof artifacts.ReverseRegistrar)["abi"]>(
        "ReverseRegistrar",
      );

    const standaloneHCAFactory = get<
      (typeof artifacts.StandaloneHCAFactory)["abi"]
    >("StandaloneHCAFactory");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const previousAdapter = getOrNull("ReverseRegistrarAdapter");
    const priorControllers = [previousAdapter];
    const adapter = await deploy(
      "ReverseRegistrarAdapter",
      {
        account: deployer,
        artifact: artifacts.ReverseRegistrarAdapter,
        args: [
          reverseRegistrar.address,
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

    for (const previousAddress of replacedDeploymentAddresses(
      adapter,
      priorControllers,
    )) {
      const previousIsController = await read(reverseRegistrar, {
        functionName: "controllers",
        args: [previousAddress],
      });
      if (previousIsController) {
        await write(reverseRegistrar, {
          account: v1Owner ?? owner,
          functionName: "setController",
          args: [previousAddress, false],
        });
      }
    }
  },
  {
    tags: [
      "ReverseRegistrarAdapter",
      "migration:phase1:deploy-v2",
      "v2",
      "hca",
    ],
    dependencies: ["ContractNamer", "StandaloneHCAFactory"],
  },
);
