import { execute } from "@rocketh";
import { readFile } from "fs/promises";
import type { Abi_UniversalResolverV2 } from "generated/abis/UniversalResolverV2.ts";
import { Artifact_UpgradableUniversalResolverProxy } from 'generated/artifacts/UpgradableUniversalResolverProxy.js';
import { resolve } from "path";
import type { Deployment } from "rocketh/types";
import type { Abi } from 'viem';

const __dirname = new URL(".", import.meta.url).pathname;
const deploymentsPath = resolve(
  __dirname,
  "../../lib/ens-contracts/deployments",
);

export default execute(
  async ({
    deploy,
    get,
    namedAccounts: { deployer, owner },
    tags,
    name
  }) => {
    if (tags.local) {
      const universalResolver = get<
        Abi_UniversalResolverV2
      >("UniversalResolverV2");
      await deploy("UpgradableUniversalResolverProxy", {
        account: deployer,
        artifact: Artifact_UpgradableUniversalResolverProxy,
        args: [owner, universalResolver.address],
      });
      return;
    }

    const v1UniversalResolverDeployment = await readFile(
      resolve(deploymentsPath, `${name}/UniversalResolver.json`),
      "utf-8",
    );
    const v1UniversalResolverDeploymentJson = JSON.parse(
      v1UniversalResolverDeployment,
    ) as Deployment<Abi>;

    await deploy("UpgradableUniversalResolverProxy", {
      account: deployer,
      artifact: Artifact_UpgradableUniversalResolverProxy,
      args: [owner, v1UniversalResolverDeploymentJson.address],
    });
  },
  { tags: ["UpgradableUniversalResolverProxy", "v2", "UniversalResolverV2"] },
);
