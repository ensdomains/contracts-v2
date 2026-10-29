import { execute } from "@rocketh";
import { Artifact_MockERC20 } from "generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js";
import {
  isPinnedMockBuild,
  PINNED_MOCK_USDC,
} from "../script/pinnedMockTokens.js";

export default execute(
  async ({ deploy, getOrNull, namedAccounts: { deployer }, tags }) => {
    // Free-mint mock payment tokens must never ship to mainnet; the price
    // oracle wires real tokens there instead.
    if (tags.hasDao) return;

    // Keep an existing capped mock so its pinned address survives metadata-only
    // changes; replace anything else, e.g. an uncapped one.
    const existing = getOrNull(PINNED_MOCK_USDC.name);
    if (!existing || !isPinnedMockBuild(existing, PINNED_MOCK_USDC)) {
      await deploy(PINNED_MOCK_USDC.name, {
        account: deployer,
        artifact: PINNED_MOCK_USDC.artifact,
        args: [...PINNED_MOCK_USDC.args],
      });
    }

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
