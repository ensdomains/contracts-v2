import { artifacts, execute } from "@rocketh";
import { getAddress, zeroAddress } from "viem";

import {
  knownProxyNetworkName,
  loadKnownIntermediateUrpDeployment,
} from "../../script/universalResolverDeployUtils.js";

export default execute(
  async ({
    deploy,
    get,
    getV1,
    getOrNull,
    save,
    read,
    namedAccounts: { deployer, urManager },
    name,
    tags,
  }) => {
    if (tags.local) return true;

    if (
      getOrNull<typeof artifacts.UpgradableUniversalResolverProxy.abi>(
        "ManagedUniversalResolverProxy",
      )
    )
      return true;

    // Reuse a long-lived intermediate URP when one already fronts the top URP on
    // this network. A fresh v2 deployment then only re-points this proxy at the
    // new implementation, leaving the externally-administered top URP untouched.
    const knownIntermediate = await loadKnownIntermediateUrpDeployment(
      knownProxyNetworkName(tags, name),
    );
    if (knownIntermediate) {
      await save("ManagedUniversalResolverProxy", knownIntermediate);
      return true;
    }

    // No pre-existing intermediate URP: deploy one seeded with whatever the top
    // proxy currently serves so that later switching the top proxy onto it is
    // transparent for resolution. Fall back to the v1 UniversalResolver only when
    // the top proxy implementation is unset.
    const topProxy =
      get<typeof artifacts.UpgradableUniversalResolverProxy.abi>(
        "UpgradableUniversalResolverProxy",
      );
    const topImplementation = (await read(topProxy, {
      functionName: "implementation",
    })) as `0x${string}`;
    const seedImplementation =
      getAddress(topImplementation) !== getAddress(zeroAddress)
        ? topImplementation
        : (
            await getV1<(typeof artifacts.UniversalResolver)["abi"]>(
              "UniversalResolver",
            )
          ).address;

    await deploy("ManagedUniversalResolverProxy", {
      account: deployer,
      artifact: artifacts.UpgradableUniversalResolverProxy,
      args: [urManager ?? deployer, seedImplementation],
    });
    return true;
  },
  {
    id: "universal-resolver:deploy-managed-urp:v1",
    tags: [
      "UniversalResolverMigration",
      "migration:phase1:deploy-v2",
      "ManagedUniversalResolverProxy",
      "v2",
    ],
    dependencies: ["UniversalResolverV1"],
  },
);
