import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ execute: write, get, read, namedAccounts: { deployer, owner } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>(
      "HCAFactory",
    );
    const deferredImplementation = get<
      (typeof artifacts.HCADeferredImplementation)["abi"]
    >("HCADeferredImplementation");

    const currentDeferredImplementation = await read(hcaFactory, {
      functionName: "deferredImplementation",
      args: [],
    });

    if (currentDeferredImplementation !== deferredImplementation.address) {
      await write(hcaFactory, {
        account: owner || deployer,
        functionName: "setDeferredImplementation",
        args: [deferredImplementation.address],
      });
    }

    const setupAccounts = Array.from(new Set([deployer, owner || deployer]));
    for (const account of setupAccounts) {
      const currentAccountImplementation = await read(hcaFactory, {
        functionName: "accountImplementationOf",
        args: [account],
      });

      if (
        currentAccountImplementation ===
        "0x0000000000000000000000000000000000000000"
      ) {
        await write(hcaFactory, {
          account,
          functionName: "setAccountImplementation",
          args: [deferredImplementation.address],
        });
      }
    }
  },
  {
    tags: ["SetupHCAFactory", "v2"],
    dependencies: ["HCAFactory", "HCADeferredImplementation"],
  },
);
