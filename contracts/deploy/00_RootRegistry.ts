import { artifacts, execute } from "@rocketh";
import { DEPLOYMENT_ROLES, ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    get,
    execute: write,
    namedAccounts: { deployer, owner },
  }) => {
    const hcaFactory =
      get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    const rootRegistry = await deploy("RootRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
        labelStore.address,
        deployer,
        DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
      ],
    });

    console.log("  - Granting CAN_NAME to owner");
    await write(rootRegistry, {
      functionName: "grantRootRoles",
      args: [ROLES.REGISTRY.CAN_NAME, owner],
      account: deployer,
    });
  },
  {
    tags: ["RootRegistry", "v2"],
    dependencies: ["HCAFactory", "LabelStore"],
  },
);
