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
    getV1,
    namedAccounts: { deployer, owner },
  }) => {
    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const rentPriceOracle = get<(typeof artifacts.IRentPriceOracle)["abi"]>(
      "StandardRentPriceOracle",
    );

    const verifiableFactory =
      get<(typeof artifacts.VerifiableFactory)["abi"]>("VerifiableFactory");

    const trustedHCASet =
      get<(typeof artifacts.PermissionedAddressSet)["abi"]>("TrustedHCASet");

    const nameWrapper =
      await getV1<(typeof artifacts.NameWrapper)["abi"]>("NameWrapper");

    const wrappedController = await getV1<
      (typeof artifacts.IWrappedETHRegistrarController)["abi"]
    >("WrappedETHRegistrarController");

    const ethRenewerV1 = await deploy("ETHRenewerV1", {
      account: deployer,
      artifact: artifacts.ETHRenewerV1,
      args: [
        owner,
        ethRegistry.address,
        owner, // TODO: beneficiary,
        rentPriceOracle.address,
        verifiableFactory.address,
        trustedHCASet.address,
        GRACE_PERIOD_V2,
        PREMIGRATION_BONUS_PERIOD,
        nameWrapper.address,
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
    tags: ["ETHRenewerV1", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "ETHRegistry",
      "StandardRentPriceOracle",
      "VerifiableFactory",
      "TrustedHCASet",
      "NameWrapper",
      "WrappedETHRegistrarController",
    ],
  },
);
