import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const MockERC20 = artifacts["test/mocks/MockERC20.sol/MockERC20"];

    await deploy("MockUSDC", {
      account: deployer,
      artifact: MockERC20,
      args: ["USDC", 6, hcaFactory.address],
    });

    await deploy("MockDAI", {
      account: deployer,
      artifact: MockERC20,
      args: ["DAI", 18, hcaFactory.address],
    });
  },
  {
    tags: ["MockTokens", "l1"],
    dependencies: ["HCAFactory"],
  },
);
