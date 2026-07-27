import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer, owner } }) => {
    const trustedHCASet = await deploy("TrustedHCASet", {
      account: deployer,
      artifact: artifacts.PermissionedAddressSet,
      args: [owner],
    });

    // example: trust an implementation
    // await write(trustedHCASet, {
    //   account: owner,
    //   functionName: "approve",
    //   args: [<impl>, true],
    // });
  },
  { tags: ["TrustedHCASet", "v2"] },
);
