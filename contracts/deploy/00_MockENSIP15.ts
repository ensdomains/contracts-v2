import { execute } from "@rocketh";
import { Artifact_MockENSIP15 } from "generated/artifacts/MockENSIP15.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("MockENSIP15", {
      account: deployer,
      artifact: Artifact_MockENSIP15,
    });
  },
  {
    tags: ["MockENSIP15", "v2"],
  },
);
