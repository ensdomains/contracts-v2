import { artifacts, execute } from "@rocketh";
import {
  DEPLOYMENT_ROLES,
  GRACE_PERIOD_V2,
  MIN_COMMITMENT_AGE,
  MAX_COMMITMENT_AGE,
  MIN_REGISTER_DURATION,
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

    const rentPriceOracle = get<(typeof artifacts.IRentPriceOracle)["abi"]>(
      "StandardRentPriceOracle",
    );

    const ethRegistrar = await deploy("ETHRegistrar", {
      account: deployer,
      artifact: artifacts.ETHRegistrar,
      args: [
        owner,
        hcaFactory.address,
        ethRegistry.address,
        owner, // TODO: beneficiary,
        rentPriceOracle.address,
        GRACE_PERIOD_V2,
        MIN_COMMITMENT_AGE,
        MAX_COMMITMENT_AGE,
        MIN_REGISTER_DURATION,
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
    dependencies: ["HCAFactory", "ETHRegistry", "StandardRentPriceOracle"],
  },
);
