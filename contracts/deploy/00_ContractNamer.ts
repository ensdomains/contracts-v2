import { artifacts, execute } from "@rocketh";
import type { Abi } from "abitype";

export default execute(
  async ({ deploy, deployViaProxy, namedAccounts: { deployer, owner } }) => {
    await deployViaProxy<Abi>(
      "ContractNamer",
      {
        account: deployer,
        artifact: (name) =>
          deploy(name, {
            account: deployer,
            artifact: artifacts.ContractNamer,
          }),
        args: [owner || deployer],
      },
      {
        proxyContract: "UUPS",
        execute: "initialize",
      },
    );
  },
  {
    tags: ["ContractNamer", "v2"],
  },
);
