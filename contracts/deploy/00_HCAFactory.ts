import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    await deploy("HCAFactory", {
      account: deployer,
      artifact: artifacts.HCAFactory,
      args: [verifiableFactory.address, owner || deployer],
    });
  },
  {
    tags: ["HCAFactory", "v2"],
    dependencies: ["VerifiableFactory"],
  },
);
