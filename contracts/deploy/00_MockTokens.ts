import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer }, tags }) => {
    // Free-mint mock payment tokens must never ship to mainnet; the price
    // oracle wires real tokens there instead.
    if (tags.hasDao) return;

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

    await deploy("MockWETH", {
      account: deployer,
      artifact: MockERC20,
      args: ["WETH", 18],
    });

    const ethPrice = 2000;
    const decimals = 8; // arbitrary, matches mainnet
    await deploy("MockChainlinkETHUSD", {
      account: deployer,
      artifact: artifacts.MockChainlinkAggregator,
      args: [BigInt(ethPrice) * 10n ** BigInt(decimals), decimals],
    });
    console.log(`USD/ETH = $${ethPrice}`);
  },
  {
    tags: ["MockTokens", "migration:phase1:deploy-v2", "v2"],
  },
);
