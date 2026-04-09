import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const ensRegistryV1 =
      get<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    await deploy("Graveyard", {
      account: deployer,
      artifact: artifacts.Graveyard,
      args: [ensRegistryV1.address],
    });
  },
  {
    tags: ["Graveyard", "v2"],
    dependencies: ["ENSRegistry"],
  },
);
