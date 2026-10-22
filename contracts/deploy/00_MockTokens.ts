import { execute } from "@rocketh";
import { Artifact_MockChainlinkAggregator } from "generated/artifacts/MockChainlinkAggregator.js";
import { Artifact_MockERC20 } from "generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer }, tags }) => {
    // Free-mint mock payment tokens must never ship to mainnet; the price
    // oracle wires real tokens there instead.
    if (tags.hasDao) return;

    await deploy("MockUSDC", {
      account: deployer,
      artifact: Artifact_MockERC20,
      args: ["USDC", 6],
    });

    await deploy("MockDAI", {
      account: deployer,
      artifact: Artifact_MockERC20,
      args: ["DAI", 18],
    });

    await deploy("MockWETH", {
      account: deployer,
      artifact: Artifact_MockERC20,
      args: ["WETH", 18],
    });

    const ethPrice = 2000;
    const decimals = 8; // arbitrary, matches mainnet
    const maxAge = 3600n; // arbitrary
    await deploy("MockChainlinkETHUSD", {
      account: deployer,
      artifact: Artifact_MockChainlinkAggregator,
      args: [BigInt(ethPrice) * 10n ** BigInt(decimals), maxAge, decimals],
    });
    console.log(`USD/ETH = $${ethPrice}`);
  },
  {
    tags: ["MockTokens", "migration:phase1:deploy-v2", "v2"],
  },
);
