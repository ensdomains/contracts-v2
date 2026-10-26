import { execute } from "@rocketh";
import { encodeFunctionData, isAddressEqual, parseEventLogs } from "viem/utils";
import type { Abi_INameWrapper } from "generated/abis/INameWrapper.js";
import type { Abi_Graveyard } from "generated/abis/Graveyard.js";
import type { Abi_IPermissionedRegistry } from "generated/abis/IPermissionedRegistry.js";
import type { Abi_IVerifiableFactory } from "generated/abis/IVerifiableFactory.js";
import type { Abi_WrapperRegistry } from "generated/abis/WrapperRegistry.js";
import type { Abi_IAddressSet } from "generated/abis/IAddressSet.js";
import type { Abi_PublicResolverV2 } from "generated/abis/PublicResolverV2.js";
import { Artifact_LockedMigrationController } from "generated/artifacts/LockedMigrationController.js";
import { DEPLOYMENT_ROLES, ROLES } from "../script/deploy-constants.js";
import { idFromLabel } from "../test/utils/utils.js";

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getOrNull,
    getV1,
    read,
    save,
    namedAccounts: { deployer, owner },
  }) => {
    const nameWrapper = await getV1<Abi_INameWrapper>("NameWrapper");
    const graveyard = get<Abi_Graveyard>("Graveyard");
    const ethRegistry = get<Abi_IPermissionedRegistry>("ETHRegistry");
    const verifiableFactory = get<Abi_IVerifiableFactory>("VerifiableFactory");
    const wrapperRegistryImpl = get<Abi_WrapperRegistry>("WrapperRegistryImpl");
    const publicResolverSet = get<Abi_IAddressSet>("PublicResolverSet");
    const publicResolverV2 = get<Abi_PublicResolverV2>("PublicResolverV2");

    const migrationControllerImpl = await deploy(
      "LockedMigrationControllerImpl",
      {
        account: deployer,
        artifact: Artifact_LockedMigrationController,
        args: [
          nameWrapper.address,
          graveyard.address,
          ethRegistry.address,
          verifiableFactory.address,
          wrapperRegistryImpl.address,
          publicResolverSet.address,
          publicResolverV2.address,
          owner, // impl namer
        ],
      },
    );

    let migrationControllerProxy = getOrNull<
      (typeof Artifact_LockedMigrationController)["abi"]
    >("LockedMigrationController");
    if (migrationControllerProxy) {
      if (migrationControllerImpl.newlyDeployed) {
        const currentOwner = await read(migrationControllerProxy, {
          functionName: "owner",
        });
        if (isAddressEqual(currentOwner, deployer)) {
          await write(migrationControllerProxy, {
            account: deployer,
            functionName: "upgradeToAndCall",
            args: [
              migrationControllerImpl.address,
              "0x", // TODO: depends on future implementation
            ],
          });
        } else {
          console.warn(
            `  -- Warn: LockedMigrationController requires upgrade to ${migrationControllerImpl.address}`,
          );
        }
      }
    } else {
      const proxyDeployment = await write(verifiableFactory, {
        account: deployer,
        functionName: "deployProxy",
        args: [
          migrationControllerImpl.address,
          idFromLabel("LockedMigrationController"),
          encodeFunctionData({
            abi: Artifact_LockedMigrationController.abi,
            functionName: "initialize",
            args: [owner],
          }),
        ],
      });

      const [log] = parseEventLogs({
        abi: verifiableFactory.abi,
        eventName: "ProxyDeployed",
        logs: proxyDeployment.logs as any,
      });
      const controllerAddress = log.args.proxyAddress;

      // TODO: is this correct?
      migrationControllerProxy = {
        ...migrationControllerImpl,
        address: controllerAddress,
        receipt: {
          blockHash: proxyDeployment.blockHash,
          blockNumber: proxyDeployment.blockNumber,
          transactionIndex: proxyDeployment.transactionIndex,
        },
      };
      await save("LockedMigrationController", migrationControllerProxy);
    }

    const controllerRoles = DEPLOYMENT_ROLES.MIGRATION_CONTROLLER_ROOT;
    const proxyHasGrant = await read(ethRegistry, {
      functionName: "hasRootRoles",
      args: [controllerRoles, migrationControllerProxy.address],
    });
    if (!proxyHasGrant) {
      const adminRoles = (controllerRoles | (controllerRoles >> 128n)) << 128n;
      const deployerCanGrant = await read(ethRegistry, {
        functionName: "hasRootRoles",
        args: [adminRoles, deployer],
      });
      if (deployerCanGrant) {
        await write(ethRegistry, {
          account: deployer,
          functionName: "grantRootRoles",
          args: [controllerRoles, migrationControllerProxy.address],
        });
      } else {
        console.warn(
          `  -- Warn: LockedMigrationController requires root roles`,
        );
      }
    }
  },
  {
    tags: ["LockedMigrationController", "migration:phase1:deploy-v2", "v2"],
    dependencies: [
      "NameWrapper",
      "Graveyard",
      "ETHRegistry",
      "VerifiableFactory",
      "WrapperRegistryImpl",
      "PublicResolverSet",
      "PublicResolverV2",
    ],
  },
);
