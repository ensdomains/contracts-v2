import type { NewTaskActionFunction } from "hardhat/types/tasks";

import {
  checkBatchRegistrarOwner,
  parseMigrationNetwork,
} from "../../../script/migration.js";
import { optionalAddress, optionalString, requireHttpNetwork } from "./utils.js";

type BatchRegistrarOwnerTaskArgs = {
  migrationNetwork: string;
  deploymentNetwork: string;
  deploymentsDir: string;
  batchRegistrar: string;
  expectedOwner: string;
  chainId: string;
};

const action: NewTaskActionFunction<BatchRegistrarOwnerTaskArgs> = async (args, hre) => {
  const connection = await hre.network.connect();
  try {
    const networkConfig = requireHttpNetwork(
      connection.networkConfig,
      "migration batch-registrar-owner",
      connection.networkName,
    );

    await checkBatchRegistrarOwner({
      network: parseMigrationNetwork(args.migrationNetwork),
      rpcUrl: await networkConfig.url.getUrl(),
      chainId: optionalString(args.chainId),
      deploymentNetwork: optionalString(args.deploymentNetwork),
      deploymentsDir: args.deploymentsDir,
      batchRegistrar: optionalAddress(args.batchRegistrar),
      expectedOwner: optionalAddress(args.expectedOwner),
    });
  } finally {
    await connection.close();
  }
};

export default action;
