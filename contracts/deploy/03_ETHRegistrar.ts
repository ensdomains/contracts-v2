import { artifacts, execute } from "@rocketh";
import {
  DEPLOYMENT_ROLES,
  MIN_COMMITMENT_AGE,
  MAX_COMMITMENT_AGE,
  GRACE_PERIOD_V2,
  MIN_REGISTER_DURATION,
  MIN_RENEW_DURATION,
} from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer, owner },
  }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    const ethRenewerV1 =
      get<(typeof artifacts.ETHRenewerV1)["abi"]>("ETHRenewerV1");

    const rentPriceOracle = get<(typeof artifacts.IRentPriceOracle)["abi"]>(
      "StandardRentPriceOracle",
    );

    const ethRegistrar = await deploy("ETHRegistrar", {
      account: deployer,
      artifact: artifacts.ETHRegistrar,
      args: [
        hcaFactory.address,
        ethRegistry.address,
        ethRenewerV1.address,
        owner, // beneficiary,
        MIN_COMMITMENT_AGE,
        MAX_COMMITMENT_AGE,
        GRACE_PERIOD_V2,
        MIN_REGISTER_DURATION,
        MIN_RENEW_DURATION,
        rentPriceOracle.address,
      ],
    });

    await write(ethRegistry, {
      functionName: "grantRootRoles",
      args: [DEPLOYMENT_ROLES.ETH_REGISTRAR_ROOT, ethRegistrar.address],
      account: deployer,
    });
  },
  {
    tags: ["ETHRegistrar", "v2"],
    dependencies: [
      "HCAFactory",
      "ETHRegistry",
      "ETHRenewerV1",
      "StandardRentPriceOracle",
    ],
  },
);
