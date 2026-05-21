import { artifacts, execute } from "@rocketh";
import { zeroAddress } from "viem";

export default execute(
  async ({ execute: write, get, read, namedAccounts: { deployer, owner } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>(
      "HCAFactory",
    );

    const deferredImplementation = await read(hcaFactory, {
      functionName: "deferredImplementation",
      args: [],
    });

    const setupAccounts = Array.from(new Set([deployer, owner || deployer]));
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
    tags: ["SetupHCAFactory", "v2"],
    dependencies: ["HCAFactory"],
  },
);
