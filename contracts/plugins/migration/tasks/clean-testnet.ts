import type { NewTaskActionFunction } from "hardhat/types/tasks";

import { parseMigrationNetwork, runCleanTestnetFull } from "../../../script/migration.js";
import {
  isTenderlyVirtualRpc,
  logMigrationSigners,
  optionalString,
  requireHttpNetwork,
  resolveMigrationSigners,
} from "./utils.js";

type CleanTestnetTaskArgs = {
  migrationNetwork: string;
  chainId: string;
  csvFile: string;
  batchSize: string;
  initialLimit: string;
  finishLimit: string;
  workDir: string;
  deploymentsDir: string;
  deploymentNetwork: string;
  v1DeploymentsDir: string;
  v1DeploymentNetwork: string;
  snapshotFile: string;
  deployer: string;
  owner: string;
  v1Owner: string;
  urManager: string;
  resumeExistingDeployments: boolean;
  debugRpc: boolean;
  keepAnvil: boolean;
};

const action: NewTaskActionFunction<CleanTestnetTaskArgs> = async (args, hre) => {
  const connection = await hre.network.connect();
  try {
    const networkConfig = requireHttpNetwork(
      connection.networkConfig,
      "migration clean-testnet",
      connection.networkName,
    );
    const rpcUrl = await networkConfig.url.getUrl();
    const signers = await resolveMigrationSigners({
      args,
      networkConfig,
      provider: connection.provider,
      ownerFallback: "deployer",
      taskName: "migration clean-testnet",
    });
    logMigrationSigners(signers);

    await runCleanTestnetFull({
      network: parseMigrationNetwork(args.migrationNetwork),
      rpcUrl,
      provider: connection.provider,
      direct: true,
      chainId: optionalString(args.chainId),
      csvFile: optionalString(args.csvFile),
      batchSize: optionalString(args.batchSize),
      initialLimit: optionalString(args.initialLimit),
      finishLimit: optionalString(args.finishLimit),
      workDir: optionalString(args.workDir),
      deploymentsDir: args.deploymentsDir,
      deploymentNetwork: optionalString(args.deploymentNetwork),
      v1DeploymentsDir: optionalString(args.v1DeploymentsDir),
      v1DeploymentNetwork: optionalString(args.v1DeploymentNetwork),
      tenderly: isTenderlyVirtualRpc(rpcUrl),
      snapshotFile: optionalString(args.snapshotFile),
      ...signers,
      resumeExistingDeployments: args.resumeExistingDeployments,
      debugRpc: args.debugRpc,
      keepAnvil: args.keepAnvil,
    });
  } finally {
    await connection.close();
  }
};

export default action;
