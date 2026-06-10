import { artifacts, execute } from "@rocketh";

import {
  isDeployedTopProxy,
  loadKnownTopProxyDeployment,
  TOP_URP_CREATE3_SALT,
} from "../../script/universalResolverDeployUtils.js";

export default execute(
  async ({
    deploy,
    getV1,
    getOrNull,
    save,
    namedAccounts: { deployer, owner },
    name,
    tags,
  }) => {
    if (tags.local) return true;

    const v1UniversalResolver =
      await getV1<(typeof artifacts.UniversalResolver)["abi"]>(
        "UniversalResolver",
      );
    if (tags["clean-testnet"]) {
      await deploy("UpgradableUniversalResolverProxy", {
        account: deployer,
        artifact: artifacts.UpgradableUniversalResolverProxy,
        args: [owner, v1UniversalResolver.address],
      });
      return true;
    }

    const currentDeployment = getOrNull<
      typeof artifacts.UpgradableUniversalResolverProxy.abi
    >("UpgradableUniversalResolverProxy");
    const currentTopProxyDeployment =
      currentDeployment && isDeployedTopProxy(currentDeployment)
        ? currentDeployment
        : null;
    const knownProxyNetwork = tags.sepolia
      ? "sepolia"
      : tags.hasDao
        ? "mainnet"
        : name;
    const knownTopProxyDeployment =
      await loadKnownTopProxyDeployment(knownProxyNetwork);
    const topProxyDeployment =
      currentTopProxyDeployment ?? knownTopProxyDeployment;

    if (topProxyDeployment) {
      if (!currentTopProxyDeployment) {
        await save("UpgradableUniversalResolverProxy", topProxyDeployment);
      }
      return true;
    }

    await deploy(
      "UpgradableUniversalResolverProxy",
      {
        account: deployer,
        artifact: artifacts.UpgradableUniversalResolverProxy,
        args: [owner, v1UniversalResolver.address],
      },
      {
        deterministic: {
          type: "create3",
          salt: TOP_URP_CREATE3_SALT,
        },
        alwaysOverride: true,
      },
    );
    return true;
  },
  {
    id: "universal-resolver:deploy-universal-resolver:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase1:deploy-v2",
      "UniversalResolver",
      "UpgradableUniversalResolverProxy",
      "v2",
    ],
  },
);
