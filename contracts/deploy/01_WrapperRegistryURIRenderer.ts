import { execute } from "@rocketh";
import type { Abi_IRegistryURIRenderer } from "generated/abis/IRegistryURIRenderer.js";
import { Artifact_BoxedURIRenderer } from "generated/artifacts/BoxedURIRenderer.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const uriRenderer = get<Abi_IRegistryURIRenderer>("ENSURIRenderer");

    await deploy("WrapperRegistryURIRenderer", {
      account: deployer,
      artifact: Artifact_BoxedURIRenderer,
      args: [owner, uriRenderer.address],
    });
  },
  {
    tags: ["WrapperRegistryURIRenderer", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["ENSURIRenderer"],
  },
);
