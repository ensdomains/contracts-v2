import { artifacts, execute } from "@rocketh";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>(
      "HCAFactory",
    );

    const labelStore = get<(typeof artifacts.ILabelStore)["abi"]>("LabelStore");

    await deploy("RootRegistry", {
      account: deployer,
      artifact: artifacts.PermissionedRegistry,
      args: [
        hcaFactory.address,
        labelStore.address,
        deployer,
        DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
      ],
    });
  },
  {
    tags: ["RootRegistry", "v2"],
    dependencies: ["HCAFactory", "LabelStore"],
  },
);
