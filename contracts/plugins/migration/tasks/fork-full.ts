import type { NewTaskActionFunction } from "hardhat/types/tasks";

import { parseMigrationNetwork, runForkFull } from "../../../script/migration.js";
import {
  isTenderlyVirtualRpc,
  logMigrationSigners,
  optionalString,
  requireHttpNetwork,
  resolveMigrationSigners,
} from "./utils.js";

type ForkFullTaskArgs = {
  migrationNetwork: string;
  direct: boolean;
  chainId: string;
  port: string;
  csvFile: string;
  batchSize: string;
  initialLimit: string;
  finishLimit: string;
  workDir: string;
  resumeFromPhase: string;
  saveDeployments: boolean;
  deploymentsDir: string;
  deploymentNetwork: string;
  v1DeploymentsDir: string;
  v1DeploymentNetwork: string;
  snapshotFile: string;
  deployer: string;
  owner: string;
  v1Owner: string;
  urManager: string;
  includeTestnetPremigrationRegistrar: boolean;
  debugRpc: boolean;
  keepAnvil: boolean;
};

const action: NewTaskActionFunction<ForkFullTaskArgs> = async (args, hre) => {
  if (args.csvFile === "") {
    throw new Error("migration fork-full requires --csv-file");
  }

  const connection = await hre.network.connect();
  try {
    const networkConfig = requireHttpNetwork(
      connection.networkConfig,
      "migration fork-full",
      connection.networkName,
    );
    const rpcUrl = await networkConfig.url.getUrl();
    const signers = await resolveMigrationSigners({
      args,
      networkConfig,
      provider: connection.provider,
      ownerFallback: "hardhat",
      taskName: "migration fork-full",
    });
    logMigrationSigners(signers);

    await runForkFull({
      network: parseMigrationNetwork(args.migrationNetwork),
      rpcUrl,
      direct: args.direct,
      chainId: optionalString(args.chainId),
      port: optionalString(args.port),
      csvFile: args.csvFile,
      batchSize: optionalString(args.batchSize),
      initialLimit: optionalString(args.initialLimit),
      finishLimit: optionalString(args.finishLimit),
      workDir: optionalString(args.workDir),
      resumeFromPhase: optionalString(args.resumeFromPhase),
      saveDeployments: args.saveDeployments,
      deploymentsDir: args.deploymentsDir,
      deploymentNetwork: optionalString(args.deploymentNetwork),
      v1DeploymentsDir: optionalString(args.v1DeploymentsDir),
      v1DeploymentNetwork: optionalString(args.v1DeploymentNetwork),
      tenderly: isTenderlyVirtualRpc(rpcUrl),
      includeTestnetPremigrationRegistrar: args.includeTestnetPremigrationRegistrar,
      snapshotFile: optionalString(args.snapshotFile),
      ...signers,
      debugRpc: args.debugRpc,
      keepAnvil: args.keepAnvil,
    });
  } finally {
    await connection.close();
  }
};

export default action;
