import { execute } from "@rocketh";
import { Artifact_StaticURIRenderer } from "generated/artifacts/StaticURIRenderer.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer }, network }) => {
    const prefix = `https://metadata.ens.domains/${network.chain.name.toLowerCase()}/0x`;
    const afterRegistry = "/";
    const afterToken = ".json";

    console.log(
      `  - Metadata URL: ${prefix}{registry}${afterRegistry}{token}${afterToken}`,
    );

    await deploy("SharedURIRenderer", {
      account: deployer,
      artifact: Artifact_StaticURIRenderer,
      args: [prefix, afterRegistry, afterToken],
    });
  },
  { tags: ["SharedURIRenderer", "migration:phase1:deploy-v2", "v2"] },
);
