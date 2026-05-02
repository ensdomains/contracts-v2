import { artifacts, execute } from "@rocketh";
import {
  DEPLOYMENT_ROLES,
  PREMIGRATION_BONUS_PERIOD,
} from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer, owner },
  }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const wrappedController = get<
      (typeof artifacts.IWrappedETHRegistrarController)["abi"]
    >("WrappedETHRegistrarController");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const ethRenewerV1 = await deploy("ETHRenewerV1", {
      account: deployer,
      artifact: artifacts.ETHRenewerV1,
      args: [
        owner,
        nameWrapper.address,
        wrappedController.address,
        ethRegistry.address,
        PREMIGRATION_BONUS_PERIOD,
      ],
    });

    await write(ethRegistry, {
      functionName: "grantRootRoles",
      args: [DEPLOYMENT_ROLES.ETH_RENEWER_V1_ROOT, ethRenewerV1.address],
      account: deployer,
    });
  },
  {
    tags: ["ETHRenewerV1", "v2"],
    dependencies: [
      "NameWrapper",
      "WrappedETHRegistrarController",
      "ETHRegistry",
    ],
  },
);
