import { artifacts, execute } from "@rocketh";

import {
  externalTopProxyOwnerLabel,
  logUpgradeCalldata,
  setProxyImplementationIfNeeded,
} from "../../script/universalResolverDeployUtils.js";

export default execute(
  async ({
    get,
    execute: write,
    read,
    namedAccounts: { owner },
    tags,
  }) => {
    if (tags.local) return true;

    const topUrp = get<
      typeof artifacts.UpgradableUniversalResolverProxy.abi
    >("UpgradableUniversalResolverProxy");
    const managedUrp = get<
      typeof artifacts.UpgradableUniversalResolverProxy.abi
    >("ManagedUniversalResolverProxy");

    const ownerLabel = externalTopProxyOwnerLabel(tags);
    if (ownerLabel) {
      logUpgradeCalldata(
        "Set UniversalResolver implementation to ManagedUniversalResolverProxy",
        topUrp.address,
        managedUrp.address,
        ownerLabel,
      );
      return true;
    }

    await setProxyImplementationIfNeeded({
      read,
      write,
      deployment: topUrp,
      implementation: managedUrp.address,
      account: owner,
      label: "UniversalResolver implementation",
    });
    return true;
  },
  {
    id: "universal-resolver:set-universal-resolver-to-managed:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase5:switch-urp-to-managed",
      "UniversalResolverManaged",
      "v2",
    ],
    dependencies: ["ManagedUniversalResolverProxy"],
  },
);
