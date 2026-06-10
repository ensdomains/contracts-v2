import { artifacts, execute } from "@rocketh";
import { ROLES } from "../../script/deploy-constants.js";

const MOCK_PREMIGRATOR_ROLE_BITMAP =
  ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW;

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer },
    network,
    read,
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

    const hasPremigrationRoles = await read(ethRegistry, {
      functionName: "hasRootRoles",
      args: [MOCK_PREMIGRATOR_ROLE_BITMAP, mockPremigrator.address],
    });
    if (!hasPremigrationRoles) {
      await write(ethRegistry, {
        account: deployer,
        functionName: "grantRootRoles",
        args: [MOCK_PREMIGRATOR_ROLE_BITMAP, mockPremigrator.address],
      });
    }
  },
  {
    tags: ["MockPremigrator", "testnet"],
    dependencies: ["ETHRegistry"],
  },
);
