import { artifacts, execute } from "@rocketh";

export default execute(
  async ({ deploy, namedAccounts: { deployer } }) => {
    // create a new registrar for "addr.reverse"
    // TODO: update to actual reverse registrar when we have it
    await deploy("ETHReverseRegistrar", {
      account: deployer,
      artifact: artifacts['lib/ens-contracts/contracts/reverseRegistrar/L2ReverseRegistrar.sol/L2ReverseRegistrar'],
      args: [60n],
    });
  },
  {
    tags: ["ETHReverseRegistrar", "l1"],
  },
);
