import { artifacts, execute } from "@rocketh";
import { DEPLOYMENT_ROLES } from "../script/deploy-constants.js";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const nameWrapper =
      get<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const wrappedController = get<
      (typeof artifacts.IWrappedETHRegistrarController)["abi"]
    >("WrappedETHRegistrarController");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const ethRegistrar =
      get<(typeof artifacts.IRentPriceOracle)["abi"]>("ETHRegistrar");

    const ethRenewerV1 = await deploy("ETHRenewerV1", {
      account: deployer,
      artifact: artifacts.ETHRenewerV1,
      args: [
        hcaFactory.address,
        nameWrapper.address,
        wrappedController.address,
        ethRegistrar.address,
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
      "HCAFactory",
      "NameWrapper",
      "WrappedETHRegistrarController",
      "ETHRegistry",
      "ETHRegistrar",
    ],
  },
);
