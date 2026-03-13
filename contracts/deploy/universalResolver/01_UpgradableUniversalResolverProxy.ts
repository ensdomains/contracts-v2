import { artifacts, execute } from "@rocketh";
import { readFile } from "fs/promises";
import { resolve } from "path";
import type { Abi, Deployment } from "rocketh";

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
    network,
    config,
  }) => {
    if (network.tags.local) {
      const universalResolver = get<
        (typeof artifacts.UniversalResolverV2)["abi"]
      >("UniversalResolverV2");
      await deploy("UpgradableUniversalResolverProxy", {
        account: deployer,
        artifact: artifacts.UpgradableUniversalResolverProxy,
        args: [owner, universalResolver.address],
      });
      return;
    }

    const v1UniversalResolverDeployment = await readFile(
      resolve(deploymentsPath, `${config.network.name}/UniversalResolver.json`),
      "utf-8",
    );
    const v1UniversalResolverDeploymentJson = JSON.parse(
      v1UniversalResolverDeployment,
    ) as Deployment<Abi>;

    await deploy("UpgradableUniversalResolverProxy", {
      account: deployer,
      artifact: artifacts.UpgradableUniversalResolverProxy,
      args: [owner, v1UniversalResolverDeploymentJson.address],
    });
  },
  { tags: ["UpgradableUniversalResolverProxy", "v2", "UniversalResolverV2"] },
);
