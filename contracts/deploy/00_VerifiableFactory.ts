import { execute } from "@rocketh";
import { Artifact_VerifiableFactory } from "generated/artifacts/VerifiableFactory.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    // Registries, resolvers and HCA accounts are created through this factory and
    // their contracts hold its address, so a recorded one is kept. Its creation code
    // embeds the proxy's, whose metadata changes with the build's compiler settings,
    // so an unchanged factory can still compare as different.
    await deploy(
      "VerifiableFactory",
      {
        account: deployer,
        artifact: Artifact_VerifiableFactory,
      },
      { skipIfAlreadyDeployed: true },
    );
  },
  {
    tags: ["VerifiableFactory", "migration:phase1:deploy-v2", "v2"],
  },
);
