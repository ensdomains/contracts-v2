import { execute } from "@rocketh";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import { Artifact_MockERC20 } from 'generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js';

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    await deploy("MockUSDC", {
      account: deployer,
      artifact: Artifact_MockERC20,
      args: ["USDC", 6, hcaFactory.address],
    });

    await deploy("MockDAI", {
      account: deployer,
      artifact: Artifact_MockERC20,
      args: ["DAI", 18, hcaFactory.address],
    });
  },
  {
    tags: ["MockTokens", "v2"],
    dependencies: ["HCAFactory"],
  },
);
