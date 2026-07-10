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
    tags,
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

    const ethRegistrar = await deploy("ETHRegistrar", {
      account: deployer,
      artifact: artifacts.ETHRegistrar,
      args: [
        owner,
        ethRegistry.address,
        owner, // TODO: beneficiary,
        rentPriceOracle.address,
        verifiableFactory.address,
        trustedHCASet.address,
        GRACE_PERIOD_V2,
        MIN_COMMITMENT_AGE,
        MAX_COMMITMENT_AGE,
        MIN_REGISTER_DURATION,
      ],
    });

    if (!tags.deferV2Registrar) {
      await write(ethRegistry, {
        functionName: "grantRootRoles",
        args: [DEPLOYMENT_ROLES.ETH_REGISTRAR_ROOT, ethRegistrar.address],
        account: deployer,
      });
    }
  },
  {
    tags: ["ETHRegistrar", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "ETHRegistry",
      "StandardRentPriceOracle",
      "VerifiableFactory",
      "TrustedHCASet",
    ],
  },
);
