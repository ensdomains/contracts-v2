import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const MockERC20 = artifacts["test/mocks/MockERC20.sol/MockERC20"];

    await deploy("MockUSDC", {
      account: deployer,
      artifact: MockERC20,
      args: ["USDC", 6],
    });

    await deploy("MockDAI", {
      account: deployer,
      artifact: MockERC20,
      args: ["DAI", 18],
    });
  },
  {
    tags: ["MockTokens", "v2"],
  },
);
