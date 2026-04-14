import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    await deploy("Graveyard", {
      account: deployer,
      artifact: artifacts.Graveyard,
      args: [nameWrapper.address],
    });
  },
  {
    tags: ["Graveyard", "v2"],
    dependencies: ["NameWrapper"],
  },
);
