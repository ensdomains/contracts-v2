import { artifacts, execute } from "@rocketh";

import {
  logUpgradeCalldata,
  setProxyImplementationIfNeeded,
} from "../../script/universalResolverDeployUtils.js";

export default execute(
  async ({
    get,
    execute: write,
    read,
    namedAccounts: { deployer, urManager },
    tags,
  }) => {
    if (tags.local) return true;

    const managedUrp = get<
      (typeof artifacts.UpgradableUniversalResolverProxy)["abi"]
    >("ManagedUniversalResolverProxy");
    const universalResolverV2 = get<
      (typeof artifacts.UniversalResolverV2)["abi"]
    >("UniversalResolverV2");

    if (tags.hasDao) {
      logUpgradeCalldata(
        "Set ManagedUniversalResolverProxy implementation to UniversalResolverImplementation",
        managedUrp.address,
        universalResolverV2.address,
      );
      return true;
    }

    await setProxyImplementationIfNeeded({
      read,
      write,
      deployment: managedUrp,
      implementation: universalResolverV2.address,
      account: urManager ?? deployer,
      label: "ManagedUniversalResolverProxy implementation",
    });
    return true;
  },
  {
    id: "universal-resolver:set-managed-urp-to-universal-resolver-implementation:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase6:upgrade-managed-urp",
      "ManagedUniversalResolverProxyToUniversalResolverImplementation",
      "v2",
    ],
    dependencies: [
      "UniversalResolverImplementation",
      "ManagedUniversalResolverProxy",
    ],
  },
);
