import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    const trustedHCASet = await deploy("TrustedHCASet", {
      account: deployer,
      artifact: artifacts.PermissionedAddressSet,
      args: [owner],
    });

    // await write(trustedHCASet, {
    //   account: owner,
    //   functionName: "approve",
    //   args: [addr, true],
    // });
  },
  { tags: ["TrustedHCASet", "v2"] },
);
