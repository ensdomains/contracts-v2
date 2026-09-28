import { execute } from "@rocketh";
import { Artifact_StaticURIRenderer } from "generated/artifacts/StaticURIRenderer.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner }, network }) => {
    const prefix = `https://metadata.ens.domains/${network.chain.name.toLowerCase()}/0x`;
    const afterRegistry = "/";
    const afterToken = ".json";

    console.log(
      `  - Metadata URL: ${prefix}{registry}${afterRegistry}{token}${afterToken}`,
    );

    await deploy("ENSURIRenderer", {
      account: deployer,
      artifact: Artifact_StaticURIRenderer,
      args: [owner, prefix, afterRegistry, afterToken],
    });
  },
  { tags: ["ENSURIRenderer", "migration:phase1:deploy-v2", "v2"] },
);
