import { execute } from "@rocketh";
import type { Abi_IRentPriceOracle } from "generated/abis/IRentPriceOracle.ts";
import type { Abi_MockHCAFactoryBasic } from "generated/abis/MockHCAFactoryBasic.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import { Artifact_ETHRegistrar } from 'generated/artifacts/ETHRegistrar.js';
import { ROLES } from "../../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    namedAccounts: { deployer, owner },
    network,
  }) => {
    if (network.chain.id === 1) return;

    const hcaFactory =
      get<Abi_MockHCAFactoryBasic>("HCAFactory");

    const ethRegistry =
      get<Abi_PermissionedRegistry>("ETHRegistry");

    const rentPriceOracle = get<Abi_IRentPriceOracle>(
      "StandardRentPriceOracle",
    );

    const beneficiary = owner || deployer;

    const SEC_PER_DAY = 86400n;
    const ethRegistrar = await deploy("FastETHRegistrar", {
      account: deployer,
      artifact: Artifact_ETHRegistrar,
      args: [
        ethRegistry.address,
        hcaFactory.address,
        beneficiary,
        0n, // minCommitmentAge
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
    tags: ["FastETHRegistrar", "v2", "testnet"],
    dependencies: ["HCAFactory", "ETHRegistry", "StandardRentPriceOracle"],
  },
);
