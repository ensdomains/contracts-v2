import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ get, deploy, namedAccounts: { deployer } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    await deploy("Graveyard", {
      account: deployer,
      artifact: artifacts.Graveyard,
      args: [nameWrapper.address, contractNamer.address],
    });
  },
  {
    tags: ["Graveyard", "v2"],
    dependencies: ["NameWrapper", "ContractNamer"],
  },
);
