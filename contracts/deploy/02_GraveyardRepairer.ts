import { execute } from "@rocketh";
import type { Abi_Graveyard } from "generated/abis/Graveyard.js";
import { Artifact_GraveyardRepairer } from "generated/artifacts/GraveyardRepairer.js";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const graveyard = get<Abi_Graveyard>("Graveyard");

    await deploy("GraveyardRepairer", {
      account: deployer,
      artifact: Artifact_GraveyardRepairer,
      args: [graveyard.address],
    });
  },
  {
    tags: ["GraveyardRepairer", "v2"],
    dependencies: ["Graveyard"],
  },
);
