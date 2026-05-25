import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deployViaProxy, namedAccounts: { deployer, owner } }) => {
    await deployViaProxy(
      "ContractNamer",
      {
        account: deployer,
        artifact: artifacts.ContractNamer,
      },
      {
        proxyContract: "UUPS",
        execute: {
          methodName: "initialize",
          args: [owner],
        },
      },
    );
  },
  {
    tags: ["ContractNamer", "v2"],
  },
);
