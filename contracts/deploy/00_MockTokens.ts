import { execute } from "@rocketh";
import { Artifact_MockERC20 } from "generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js";
import { Artifact_MockERC20Capped } from "generated/artifacts/MockERC20Capped.js";
import { MOCK_USDC_DEPLOY_ARGS } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, namedAccounts: { deployer }, tags }) => {
    // Free-mint mock payment tokens must never ship to mainnet; the price
    // oracle wires real tokens there instead.
    if (tags.hasDao) return;

    // The USDC mock is faucet-minted by anyone, so it carries a total supply
    // ceiling and a per-call mint limit. A fresh deploy reuses the previous
    // namespace's instance while its build is unchanged (see reusePinnedMockTokens
    // in script/migrate.ts), keeping the address consumers pin stable.
    await deploy("MockUSDC", {
      account: deployer,
      artifact: Artifact_MockERC20Capped,
      args: [...MOCK_USDC_DEPLOY_ARGS],
    });

    await deploy("MockDAI", {
      account: deployer,
      artifact: Artifact_MockERC20,
      args: ["DAI", 18],
    });
  },
  {
    tags: ["MockTokens", "migration:phase1:deploy-v2", "v2"],
  },
);
