import { artifacts, execute } from "@rocketh";
import {
  DEPLOYMENT_ROLES,
  GRACE_PERIOD_V2,
  PREMIGRATION_BONUS_PERIOD,
} from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer, owner },
  }) => {
    const hcaFactory =
      get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const rentPriceOracle = get<(typeof artifacts.IRentPriceOracle)["abi"]>(
      "StandardRentPriceOracle",
    );

    const baseRegistrar = get<
      (typeof artifacts.BaseRegistrarImplementation)["abi"]
    >("BaseRegistrarImplementation");

    const wrappedController = get<
      (typeof artifacts.IWrappedETHRegistrarController)["abi"]
    >("WrappedETHRegistrarController");

    const ethRenewerV1 = await deploy("ETHRenewerV1", {
      account: deployer,
      artifact: artifacts.ETHRenewerV1,
      args: [
        owner,
        hcaFactory.address,
        ethRegistry.address,
        owner, // beneficiary,
        rentPriceOracle.address,
        GRACE_PERIOD_V2,
        PREMIGRATION_BONUS_PERIOD,
        baseRegistrar.address,
        wrappedController.address,
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
      "setup:HCAFactory",
      "ETHRegistry",
      "StandardRentPriceOracle",
      "BaseRegistrarImplementation",
      "WrappedETHRegistrarController",
    ],
  },
);
