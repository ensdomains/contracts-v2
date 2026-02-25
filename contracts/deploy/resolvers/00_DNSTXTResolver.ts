import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    await deploy("DNSTXTResolver", {
      account: deployer,
      artifact: artifacts.DNSTXTResolver,
    });
  },
  {
    tags: ["DNSTXTResolver", "l1"],
  },
);
