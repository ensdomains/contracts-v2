import { execute } from "@rocketh";
import { zeroAddress } from "viem";
import { Artifact_TrustedRegistryUpgradeAuthority } from "generated/artifacts/TrustedRegistryUpgradeAuthority.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    await deploy("TrustedRegistryUpgradeAuthority", {
      account: deployer,
      artifact: Artifact_TrustedRegistryUpgradeAuthority,
      args: [owner, zeroAddress], // TODO: add signer
    });
  },
  {
    tags: [
      "TrustedRegistryUpgradeAuthority",
      "migration:phase1:deploy-v2",
      "v2",
    ],
  },
);
