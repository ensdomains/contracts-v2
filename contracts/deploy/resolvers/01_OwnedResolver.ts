import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    await deploy("OwnedResolverV2", {
      account: deployer,
      artifact: artifacts["src/resolver/OwnedResolver.sol/OwnedResolver"],
      args: [hcaFactory.address],
    });
  },
  {
    tags: ["OwnedResolverV2", "l1"],
    dependencies: ["HCAFactory"],
  },
);
