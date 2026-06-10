import type { NewTaskActionFunction } from "hardhat/types/tasks";

import {
  parseMigrationNetwork,
  setV1ReverseDefaultResolver,
} from "../../../script/migration.js";
import {
  defaultHardhatPrivateKey,
  nonEmptyString,
  requireHttpNetwork,
} from "./utils.js";

type SetV1ReverseDefaultResolverTaskArgs = {
  migrationNetwork: string;
  chainId: string;
  v1DeploymentsDir: string;
  v1DeploymentNetwork: string;
};

const action: NewTaskActionFunction<
  SetV1ReverseDefaultResolverTaskArgs
> = async (args, hre) => {
  const connection = await hre.network.connect();
  try {
    const networkConfig = requireHttpNetwork(
      connection.networkConfig,
      "migration set-v1-reverse-default-resolver",
      connection.networkName,
    );
    const privateKey = await defaultHardhatPrivateKey(networkConfig);
    if (privateKey === undefined) {
      throw new Error(
        "migration set-v1-reverse-default-resolver could not resolve a Hardhat private key; configure DEPLOYER_KEY",
      );
    }
    await setV1ReverseDefaultResolver({
      network: parseMigrationNetwork(args.migrationNetwork),
      rpcUrl: await networkConfig.url.getUrl(),
      chainId: nonEmptyString(args.chainId),
      v1DeploymentsDir: nonEmptyString(args.v1DeploymentsDir),
      v1DeploymentNetwork: nonEmptyString(args.v1DeploymentNetwork),
      privateKey,
    });
  } finally {
    await connection.close();
  }
};

export default action;
