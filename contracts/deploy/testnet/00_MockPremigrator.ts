import { artifacts, execute } from "@rocketh";
import { ROLES } from "../../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer },
    network,
    tags,
  }) => {
    // only on testnet
    if (network.chain.id === 1) return;
    // only for dev (fresh) deployments
    if (!tags.dev) return;

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const mockPremigrator = await deploy("MockPremigrator", {
      account: deployer,
      artifact: artifacts.MockPremigrator,
      args: [ethRegistry.address],
    });

    await write(ethRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        mockPremigrator.address,
      ],
    });
  },
  {
    tags: ["MockPremigrator", "l1"],
    dependencies: [],
  },
);
