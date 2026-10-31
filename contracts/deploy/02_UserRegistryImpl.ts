import { execute } from "@rocketh";
import { Abi_IAddressSet } from "generated/abis/IAddressSet.ts";
import type { Abi_ILabelStore } from "generated/abis/ILabelStore.js";
import type { Abi_IRegistryURIRenderer } from "generated/abis/IRegistryURIRenderer.ts";
import { Artifact_UserRegistry } from "generated/artifacts/UserRegistry.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const labelStore = get<Abi_ILabelStore>("LabelStore");
    const uriRenderer = get<Abi_IRegistryURIRenderer>("BoxedENSURIRenderer");
    const upgradeAuthority = get<Abi_IAddressSet>(
      "TrustedRegistryUpgradeAuthority",
    );

    await deploy("UserRegistryImpl", {
      account: deployer,
      artifact: Artifact_UserRegistry,
      args: [
        labelStore.address,
        uriRenderer.address,
        owner,
        upgradeAuthority.address,
      ],
    });
  },
  {
    tags: ["UserRegistryImpl", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "LabelStore",
      "BoxedENSURIRenderer",
      "TrustedRegistryUpgradeAuthority",
    ],
  },
);
