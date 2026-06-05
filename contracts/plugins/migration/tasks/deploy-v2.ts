import type { NewTaskActionFunction } from "hardhat/types/tasks";

import { deployV2, parseMigrationNetwork } from "../../../script/migration.js";
import { createSnapshot, saveSnapshotFile } from "./snapshot-utils.js";
import {
  isTenderlyVirtualRpc,
  requireHttpNetwork,
  resolveMigrationSigners,
} from "./utils.js";

type DeployV2TaskArgs = {
  migrationNetwork: string;
  deploymentsDir: string;
  deploymentNetwork: string;
  v1DeploymentsDir: string;
  v1DeploymentNetwork: string;
  snapshotFile: string;
  saveDeployments: boolean;
  tags: string;
  includeTestnetPremigrationRegistrar: boolean;
  deferV1OwnerTransactions: boolean;
  deferredV1OwnerTransactionsFile: string;
  impersonateLegacyOwner: boolean;
  debugRpc: boolean;
  chainId: string;
  deployer: string;
  owner: string;
  urManager: string;
  v1Owner: string;
};

const action: NewTaskActionFunction<DeployV2TaskArgs> = async (args, hre) => {
  const connection = await hre.network.connect();
  try {
    const networkConfig = requireHttpNetwork(
      connection.networkConfig,
      "migration deploy-v2",
      connection.networkName,
    );
    const rpcUrl = await networkConfig.url.getUrl();
    const signers = await resolveMigrationSigners({
      args,
      networkConfig,
      ownerFallback: "deployer",
      taskName: "migration deploy-v2",
    });

    if (args.snapshotFile !== "") {
      const snapshotId = await createSnapshot(connection.provider);
      await saveSnapshotFile(args.snapshotFile, snapshotId, connection.networkName);
      console.log(`pre-deploy snapshot: ${snapshotId}`);
      console.log(`snapshot file: ${args.snapshotFile}`);
    }

    await deployV2({
      network: parseMigrationNetwork(args.migrationNetwork),
      rpcUrl,
      provider: connection.provider,
      chainId: args.chainId || undefined,
      deploymentsDir: args.deploymentsDir,
      deploymentNetwork: args.deploymentNetwork || undefined,
      v1DeploymentsDir: args.v1DeploymentsDir || undefined,
      v1DeploymentNetwork: args.v1DeploymentNetwork || undefined,
      saveDeployments: args.saveDeployments,
      tags: args.tags === "" ? undefined : args.tags.split(",").filter(Boolean),
      tenderly: isTenderlyVirtualRpc(rpcUrl),
      includeTestnetPremigrationRegistrar: args.includeTestnetPremigrationRegistrar,
      deferV1OwnerTransactions: args.deferV1OwnerTransactions,
      deferredV1OwnerTransactionsFile: args.deferredV1OwnerTransactionsFile || undefined,
      impersonateV1Owner: args.impersonateLegacyOwner,
      rpcCompatibility: true,
      debugRpc: args.debugRpc,
      ...signers,
    });
  } finally {
    await connection.close();
  }
};

export default action;
