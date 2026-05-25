import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";

export default execute(
  async ({
    execute: write,
    get,
    read,
    namedAccounts: { deployer, owner },
    network,
  }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>(
      "HCAFactory",
    );

    const deferredImplementation = await read(hcaFactory, {
      functionName: "DEFERRED_IMPLEMENTATION",
      args: [],
    });

    const setupAccounts = new Set([deployer]);
    if (network.name !== "mainnet" || network.tags?.tenderly) {
      setupAccounts.add(owner || deployer);
    }

    for (const account of setupAccounts) {
      const currentAccountImplementation = await read(hcaFactory, {
        functionName: "accountImplementationOf",
        args: [account],
      });

      if (currentAccountImplementation === zeroAddress) {
        await write(hcaFactory, {
          account,
          functionName: "setAccountImplementation",
          args: [deferredImplementation],
        });
      }
    }
  },
  {
    tags: ["setup:HCAFactory", "v2"],
    dependencies: ["HCAFactory"],
  },
);
