import { artifacts, execute } from "@rocketh";
import { PREMIGRATION_BONUS_PERIOD } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer, owner } }) => {
    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const wrappedController = get<
      (typeof artifacts.IWrappedETHRegistrarController)["abi"]
    >("WrappedETHRegistrarController");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    await deploy("ETHSyncer", {
      account: deployer,
      artifact: artifacts.ETHSyncer,
      args: [
        owner,
        nameWrapper.address,
        wrappedController.address,
        ethRegistry.address,
        PREMIGRATION_BONUS_PERIOD,
      ],
    });
  },
  {
    tags: ["ETHSyncer", "v2"],
    dependencies: [
      "NameWrapper",
      "WrappedETHRegistrarController",
      "ETHRegistry",
    ],
  },
);
