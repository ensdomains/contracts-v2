import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const publicResolverSet = await deploy("PublicResolverSet", {
      account: deployer,
      artifact: artifacts.PermissionedAddresses,
      args: [hcaFactory.address, deployer], // TODO: ownership
    });

    const publicResolverV1 =
      get<(typeof artifacts.PublicResolver)["abi"]>("PublicResolver");

    await write(publicResolverSet, {
      account: deployer,
      functionName: "approve",
      args: [publicResolverV1.address, true],
    });
  },
  {
    tags: ["PublicResolverSet", "v2"],
    dependencies: ["HCAFactory", "PublicResolver"],
  },
);
