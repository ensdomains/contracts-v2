import { artifacts, execute } from "@rocketh";
import { ROLES } from "../script/deploy-constants.js";

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

    const beneficiary = owner || deployer;

    const SEC_PER_DAY = 86400n;
    const ethRegistrar = await deploy("ETHRegistrar", {
      account: deployer,
      artifact: artifacts.ETHRegistrar,
      args: [
        ethRegistry.address,
        hcaFactory.address,
        beneficiary,
        60n, // minCommitmentAge
        SEC_PER_DAY, // maxCommitmentAge
        28n * SEC_PER_DAY, // minRegistrationDuration
        rentPriceOracle.address,
      ],
    });

    await write(ethRegistry, {
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        ethRegistrar.address,
      ],
      account: deployer,
    });
  },
  {
    tags: ["ETHRegistrar", "l1"],
    dependencies: ["HCAFactory", "ETHRegistry", "StandardRentPriceOracle"],
  },
);
