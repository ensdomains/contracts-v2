import { execute } from "@rocketh";
import { Artifact_DNSTXTResolver } from 'generated/artifacts/DNSTXTResolver.js';

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("DNSTXTResolver", {
      account: deployer,
      artifact: Artifact_DNSTXTResolver,
    });
  },
  {
    tags: ["DNSTXTResolver", "v2"],
  },
);
