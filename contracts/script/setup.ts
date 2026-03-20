import { rm } from "node:fs/promises";
import { anvil as createAnvil } from "prool/instances";
import type {
  UnresolvedNetworkSpecificData,
  UnresolvedUnknownNamedAccounts,
  UserConfig,
} from "rocketh/types";
import {
  type Account,
  type Address,
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  createWalletClient,
  decodeAbiParameters,
  encodeAbiParameters,
  getContract,
  type Hex,
  hexToString,
  keccak256,
  namehash,
  publicActions,
  slice,
  stringToHex,
  testActions,
  webSocket,
  zeroAddress,
} from "viem";
import { mainnet } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";

import { Artifact_GatewayProvider } from "generated/artifacts/GatewayProvider.js";
import { Artifact_DefaultReverseRegistrar } from "generated/artifacts/DefaultReverseRegistrar.js";
import { Artifact_DefaultReverseResolver } from "generated/artifacts/DefaultReverseResolver.js";
import { Artifact_L2ReverseRegistrar } from "generated/artifacts/lib/ens-contracts/contracts/reverseRegistrar/L2ReverseRegistrar.sol/L2ReverseRegistrar.js";
import { Artifact_Root } from "generated/artifacts/Root.js";
import { Artifact_ENSRegistry } from "generated/artifacts/ENSRegistry.js";
import { Artifact_BaseRegistrarImplementation } from "generated/artifacts/BaseRegistrarImplementation.js";
import { Artifact_ReverseRegistrar } from "generated/artifacts/ReverseRegistrar.js";
import { Artifact_NameWrapper } from "generated/artifacts/NameWrapper.js";
import { Artifact_RegistrarSecurityController } from "generated/artifacts/RegistrarSecurityController.js";
import { Artifact_PublicResolver } from "generated/artifacts/PublicResolver.js";
import { Artifact_UniversalResolver } from "generated/artifacts/UniversalResolver.js";
import { Artifact_SimpleRegistryMetadata } from "generated/artifacts/SimpleRegistryMetadata.js";
import { Artifact_MockHCAFactoryBasic } from "generated/artifacts/MockHCAFactoryBasic.js";
import { Artifact_VerifiableFactory } from "generated/artifacts/VerifiableFactory.js";
import { Artifact_PermissionedRegistry } from "generated/artifacts/PermissionedRegistry.js";
import { Artifact_ETHRegistrar } from "generated/artifacts/ETHRegistrar.js";
import { Artifact_StandardRentPriceOracle } from "generated/artifacts/StandardRentPriceOracle.js";
import { Artifact_MockERC20 } from "generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js";
import { Artifact_PermissionedResolver } from "generated/artifacts/PermissionedResolver.js";
import { Artifact_UserRegistry } from "generated/artifacts/UserRegistry.js";
import { Artifact_WrapperRegistry } from "generated/artifacts/WrapperRegistry.js";
import { Artifact_UnlockedMigrationController } from "generated/artifacts/UnlockedMigrationController.js";
import { Artifact_LockedMigrationController } from "generated/artifacts/LockedMigrationController.js";
import { Artifact_UniversalResolverV2 } from "generated/artifacts/UniversalResolverV2.js";
import { Artifact_DNSTLDResolver } from "generated/artifacts/DNSTLDResolver.js";
import { Artifact_DNSTXTResolver } from "generated/artifacts/DNSTXTResolver.js";
import { Artifact_DNSAliasResolver } from "generated/artifacts/DNSAliasResolver.js";
import { Artifact_ENSV1Resolver } from "generated/artifacts/ENSV1Resolver.js";
import { Artifact_ENSV2Resolver } from "generated/artifacts/ENSV2Resolver.js";
import { Artifact_UUPSProxy } from "generated/artifacts/UUPSProxy.js";

import { loadAndExecuteDeploymentsFromFilesWithConfig } from "../rocketh/environment.js";
import {
  computeVerifiableProxyAddress,
  deployVerifiableProxy,
} from "../test/integration/fixtures/deployVerifiableProxy.js";
import { dnsEncodeName } from "../test/utils/utils.js";
import { waitForSuccessfulTransactionReceipt } from "../test/utils/waitForSuccessfulTransactionReceipt.js";
import {
  LOCAL_BATCH_GATEWAY_URL,
  MAX_EXPIRY,
  ROLES,
} from "./deploy-constants.js";
import { deployArtifact } from "../test/integration/fixtures/deployArtifact.js";
import { patchArtifactsV1 } from "./patchArtifactsV1.js";

const NAMED_ACCOUNTS = ["deployer", "owner", "user", "user2"] as const;

export type StateSnapshot = () => Promise<void>;
export type DevnetEnvironment = Awaited<ReturnType<typeof setupDevnet>>;
export type DevnetAccount =
  DevnetEnvironment["namedAccounts"][(typeof NAMED_ACCOUNTS)[number]];

function ansi(c: any, s: any) {
  return `\x1b[${c}m${s}\x1b[0m`;
}

export async function setupDevnet({
  port = 0,
  mnemonic = "test test test test test test test test test test test junk",
  saveDeployments = false,
  quiet = !saveDeployments,
  procLog = false,
  extraTime = 0,
}: {
  port?: number;
  mnemonic?: string;
  saveDeployments?: boolean;
  quiet?: boolean;
  procLog?: boolean; // show anvil process logs
  extraTime?: number; // extra time to subtract from genesis timestamp
} = {}) {
  // shutdown functions for partial initialization
  const finalizers: (() => unknown | Promise<unknown>)[] = [];
  async function shutdown() {
    await Promise.allSettled(finalizers.map((f) => f()));
  }
  let unquiet = () => {};
  if (quiet) {
    const { log, table } = console;
    console.log = () => {};
    console.table = () => {};
    unquiet = () => {
      console.log = log;
      console.table = table;
    };
  }
  try {
    console.log("Deploying ENSv2...");
    await patchArtifactsV1();

    process.env["RUST_LOG"] = "info"; // required to capture console.log()
    const anvilInstance = createAnvil({
      accounts: NAMED_ACCOUNTS.length,
      mnemonic,
      chainId: mainnet.id,
      port,
      ...(extraTime
        ? { timestamp: Math.floor(Date.now() / 1000) - extraTime }
        : {}),
    });

    const accounts = NAMED_ACCOUNTS.map((name, i) =>
      Object.assign(mnemonicToAccount(mnemonic, { addressIndex: i }), {
        name,
      }),
    );

    console.log("Launching devnet");
    await anvilInstance.start();
    finalizers.push(() => anvilInstance.stop());

    // parse `host:port` from the anvil boot message
    const hostPort = (() => {
      const message = anvilInstance.messages.get().join("\n").trim();
      const match = message.match(/Listening on (.*)$/);
      if (!match) throw new Error(`expected host: ${message}`);
      return match[1];
    })();

    let showConsole = true;
    const log = (chunk: string) => {
      // ref: https://github.com/adraffy/blocksmith.js/blob/main/src/Foundry.js#L991
      const lines = chunk.split("\n").flatMap((line) => {
        if (!line) return [];
        // "2025-10-08T18:08:32.755539Z  INFO node::console: hello world"
        // "2025-10-09T16:21:27.441327Z  INFO node::user: eth_estimateGas"
        // "2025-10-09T16:24:09.289838Z  INFO node::user:     Block Number: 17"
        // "2025-10-09T16:31:48.449325Z  INFO node::user:"
        // "2025-10-09T16:31:48.451639Z  WARN backend: Skipping..."
        const match = line.match(
          /^.{27}  ([A-Z]+) (\w+(?:|::\w+)):(?:$| (.*)$)/,
        );
        if (match) {
          const [, , kind, action] = match;
          if (/^\s*$/.test(action)) return []; // collapse whitespace
          if (kind === "node::user" && /^\w+$/.test(action)) {
            showConsole = action !== "eth_estimateGas"; // detect if inside gas estimation
          }
          if (kind === "node::console") {
            return showConsole ? line : []; // ignore console during gas estimation
          }
        }
        if (!procLog) return [];
        return ansi(36, line);
      });
      if (!lines.length) return;
      console.log(lines.join("\n"));
    };
    anvilInstance.on("message", log);
    finalizers.push(() => anvilInstance.off("message", log));

    const transport = webSocket(`ws://${hostPort}`, {
      retryCount: 1,
      keepAlive: true,
      reconnect: false,
      timeout: 10000,
    });

    function createClient(account: Account) {
      return createWalletClient({
        transport,
        chain: mainnet,
        account,
        pollingInterval: 50,
        cacheTime: 0, // must be 0 due to client caching
      })
        .extend(publicActions)
        .extend(testActions({ mode: "anvil" }));
    }

    const client = createClient(accounts[0]);

    // Mock the EIP-7951 P-256 precompile at address 0x100.
    // ens-contracts v1.7.0 replaced the pure-Solidity EllipticCurve library with
    // a call to this precompile for DNSSEC P256SHA256 signature verification.
    // Anvil does not yet support EIP-7951 (requires Osaka/Fusaka hardfork), so we
    // deploy minimal bytecode that always returns 0x00...01 (valid signature).
    // Bytecode: PUSH1 0x01, PUSH0, MSTORE, PUSH1 0x20, PUSH0, RETURN
    await client.request({
      method: "anvil_setCode" as any,
      params: [
        "0x0000000000000000000000000000000000000100",
        "0x60015f5260205ff3",
      ],
    });

    console.log("Deploying contracts");
    const deploymentName = "devnet-local";
    if (saveDeployments) {
      await rm(new URL(`../deployments/${deploymentName}`, import.meta.url), {
        recursive: true,
        force: true,
      });
    }
    process.env.BATCH_GATEWAY_URLS = JSON.stringify([LOCAL_BATCH_GATEWAY_URL]);
    const rocketh = await loadAndExecuteDeploymentsFromFilesWithConfig(
      {
        environment: deploymentName,
        askBeforeProceeding: false,
        saveDeployments,
        defaultPollingInterval: 0.001, // cannot be zero
      },
      {
        accounts: Object.fromEntries(
          accounts.map((x) => [x.name, x.address]),
        ) as never,
        chains: {
          [mainnet.id]: {
            rpcUrl: `http://${hostPort}`,
            pollingInterval: 0.001,
            tags: [
              "v2",
              "local",
              "use_root", // deploy root contracts
              "allow_unsafe", // state hacks
              "legacy", // legacy registry
              "tenderly", // allow ens-contracts deploy scripts to run full setup on chain id 1
            ],
          },
        },
        environments: {
          [deploymentName]: {
            chain: mainnet.id,
            scripts: ["lib/ens-contracts/deploy", "deploy"],
          },
        },
      } satisfies UserConfig<
        UnresolvedUnknownNamedAccounts,
        UnresolvedNetworkSpecificData
      >,
    );
    console.log("Deployed contracts");

    // note: TypeScript is too slow when the following is generalized
    const shared = {
      BatchGatewayProvider: getContract({
        abi: Artifact_GatewayProvider.abi,
        address: rocketh.deployments["BatchGatewayProvider"].address,
        client,
      }),
      DefaultReverseRegistrar: getContract({
        abi: Artifact_DefaultReverseRegistrar.abi,
        address: rocketh.deployments["DefaultReverseRegistrar"].address,
        client,
      }),
      DefaultReverseResolver: getContract({
        abi: Artifact_DefaultReverseResolver.abi,
        address: rocketh.deployments["DefaultReverseResolver"].address,
        client,
      }),
      ETHReverseRegistrar: getContract({
        // TODO: update to actual reverse registrar when we have it
        abi: Artifact_L2ReverseRegistrar.abi,
        address: rocketh.deployments["ETHReverseRegistrar"].address,
        client,
      }),
    };

    const v1 = {
      Root: getContract({
        abi: Artifact_Root.abi,
        address: rocketh.deployments["Root"].address,
        client,
      }),
      ENSRegistry: getContract({
        abi: Artifact_ENSRegistry.abi,
        address: rocketh.deployments["ENSRegistry"].address,
        client,
      }),
      BaseRegistrar: getContract({
        abi: Artifact_BaseRegistrarImplementation.abi,
        address: rocketh.deployments["BaseRegistrarImplementation"].address,
        client,
      }),
      ReverseRegistrar: getContract({
        abi: Artifact_ReverseRegistrar.abi,
        address: rocketh.deployments["ReverseRegistrar"].address,
        client,
      }),
      NameWrapper: getContract({
        abi: Artifact_NameWrapper.abi,
        address: rocketh.deployments["NameWrapper"].address,
        client,
      }),
      RegistrarSecurityController: getContract({
        abi: Artifact_RegistrarSecurityController.abi,
        address: rocketh.deployments["RegistrarSecurityController"].address,
        client,
      }),
      // resolvers
      PublicResolver: getContract({
        abi: Artifact_PublicResolver.abi,
        address: rocketh.deployments["PublicResolver"].address,
        client,
      }),
      UniversalResolver: getContract({
        abi: Artifact_UniversalResolver.abi,
        address: rocketh.deployments["UniversalResolver"].address,
        client,
      }),
    };

    const v2 = {
      SimpleRegistryMetadata: getContract({
        abi: Artifact_SimpleRegistryMetadata.abi,
        address: rocketh.deployments["SimpleRegistryMetadata"].address,
        client,
      }),
      HCAFactory: getContract({
        abi: Artifact_MockHCAFactoryBasic.abi,
        address: rocketh.deployments["HCAFactory"].address,
        client,
      }),
      VerifiableFactory: getContract({
        abi: Artifact_VerifiableFactory.abi,
        address: rocketh.deployments["VerifiableFactory"].address,
        client,
      }),
      RootRegistry: getContract({
        abi: Artifact_PermissionedRegistry.abi,
        address: rocketh.deployments["RootRegistry"].address,
        client,
      }),
      ETHRegistry: getContract({
        abi: Artifact_PermissionedRegistry.abi,
        address: rocketh.deployments["ETHRegistry"].address,
        client,
      }),
      // eth registrar
      ETHRegistrar: getContract({
        abi: Artifact_ETHRegistrar.abi,
        address: rocketh.deployments["ETHRegistrar"].address,
        client,
      }),
      StandardRentPriceOracle: getContract({
        abi: Artifact_StandardRentPriceOracle.abi,
        address: rocketh.deployments["StandardRentPriceOracle"].address,
        client,
      }),
      MockUSDC: getContract({
        abi: Artifact_MockERC20.abi,
        address: rocketh.deployments["MockUSDC"].address,
        client,
      }),
      MockDAI: getContract({
        abi: Artifact_MockERC20.abi,
        address: rocketh.deployments["MockDAI"].address,
        client,
      }),
      // VerifiableFactory implementations
      PermissionedResolverImpl: getContract({
        abi: Artifact_PermissionedResolver.abi,
        address: rocketh.deployments["PermissionedResolverImpl"].address,
        client,
      }),
      UserRegistryImpl: getContract({
        abi: Artifact_UserRegistry.abi,
        address: rocketh.deployments["UserRegistryImpl"].address,
        client,
      }),
      WrapperRegistryImpl: getContract({
        abi: Artifact_WrapperRegistry.abi,
        address: rocketh.deployments["WrapperRegistryImpl"].address,
        client,
      }),
      // migration
      UnlockedMigrationController: getContract({
        abi: Artifact_UnlockedMigrationController.abi,
        address: rocketh.deployments["UnlockedMigrationController"].address,
        client,
      }),
      LockedMigrationController: getContract({
        abi: Artifact_LockedMigrationController.abi,
        address: rocketh.deployments["LockedMigrationController"].address,
        client,
      }),
      // resolvers
      UniversalResolver: getContract({
        abi: Artifact_UniversalResolverV2.abi,
        address: rocketh.deployments["UniversalResolverV2"].address,
        client,
      }),
      DNSTLDResolver: getContract({
        abi: Artifact_DNSTLDResolver.abi,
        address: rocketh.deployments["DNSTLDResolver"].address,
        client,
      }),
      DNSTXTResolver: getContract({
        abi: Artifact_DNSTXTResolver.abi,
        address: rocketh.deployments["DNSTXTResolver"].address,
        client,
      }),
      DNSAliasResolver: getContract({
        abi: Artifact_DNSAliasResolver.abi,
        address: rocketh.deployments["DNSAliasResolver"].address,
        client,
      }),
      ENSV1Resolver: getContract({
        abi: Artifact_ENSV1Resolver.abi,
        address: rocketh.deployments["ENSV1Resolver"].address,
        client,
      }),
      ENSV2Resolver: getContract({
        abi: Artifact_ENSV2Resolver.abi,
        address: rocketh.deployments["ENSV2Resolver"].address,
        client,
      }),
    };

    [shared, v1, v2]
      .flatMap((x) => Object.values(x))
      .forEach(patchContractWrite);
    console.log("Linked contracts");

    const namedAccounts = Object.fromEntries(
      await Promise.all(
        accounts.map(async (account) => {
          const resolver = await deployPermissionedResolver({
            account,
            ownedVersion: 0n,
          });
          return [account.name, Object.assign(account, { resolver })];
        }),
      ),
    ) as Record<
      (typeof NAMED_ACCOUNTS)[number],
      (typeof accounts)[number] & {
        resolver: Awaited<ReturnType<typeof deployPermissionedResolver>>;
      }
    >;
    console.log("Created PermissionedResolver for each account");

    await setupEnsDotEth();
    console.log("Setup ens.eth");

    console.log("Deployed ENSv2");
    return {
      client,
      hostPort,
      accounts,
      namedAccounts,
      rocketh,
      shared,
      v1,
      v2,
      sync,
      waitFor,
      saveState,
      shutdown,
      createClient,
      patchContractWrite,
      verifiableProxyAddress,
      deployPermissionedResolver,
      deployPermissionedRegistry,
      deployUserRegistry,
      findPermissionedRegistry,
      findWrapperRegistry,
    };

    async function waitFor(hash: Hex | Promise<Hex>) {
      return waitForSuccessfulTransactionReceipt(client, {
        hash: await hash,
      });
    }

    // inject waitForSuccessfulTransactionReceipt into viem contract wrapper
    function patchContractWrite<T extends object>(contract: T): T {
      if ("write" in contract) {
        const write0 = contract.write as Record<
          string,
          (...parameters: unknown[]) => Promise<Hex>
        >;
        contract.write = new Proxy(
          {},
          {
            get(_, functionName: string) {
              return async (...parameters: unknown[]) => {
                const promise = write0[functionName](...parameters);
                const receipt = await waitFor(
                  functionName === "safeTransferFrom" ||
                    functionName === "safeBatchTransferFrom"
                    ? promise.catch(handleTransferError) // v1 abi lacks v2 errors
                    : promise,
                );
                return receipt.transactionHash;
              };
            },
          },
        );
      }
      return contract;
    }

    async function saveState(): Promise<StateSnapshot> {
      let state = await client.request({ method: "evm_snapshot" } as any);
      let block0 = await client.getBlock();
      return async () => {
        const block1 = await client.getBlock();
        if (block0.stateRoot === block1.stateRoot) return; // noop, assuming no setStorageAt
        const ok = await client.request({
          method: "evm_revert",
          params: [state],
        } as any);
        if (!ok) throw new Error("revert failed");
        // apparently the snapshots cannot be reused
        state = await client.request({ method: "evm_snapshot" } as any);
        block0 = await client.getBlock();
      };
    }

    async function sync({
      blocks = 1,
      warpSec = "local",
    }: { blocks?: number; warpSec?: number | "local" } = {}) {
      const block = await client.getBlock();
      let timestamp = Number(block.timestamp);
      if (warpSec === "local") {
        timestamp = Math.max(timestamp, (Date.now() / 1000) | 0);
      } else {
        timestamp += warpSec;
      }
      await client.mine({
        blocks,
        interval: timestamp - Number(block.timestamp),
      });
      return BigInt(timestamp);
    }

    async function verifiableProxyAddress(args: {
      deployer: Address;
      salt: bigint;
    }) {
      return computeVerifiableProxyAddress({
        factoryAddress: v2.VerifiableFactory.address,
        bytecode: Artifact_UUPSProxy.bytecode,
        ...args,
      });
    }

    function computeOwnedResolverSalt({
      address,
      version = 0n,
    }: {
      address: Address;
      version?: bigint;
    }) {
      return BigInt(
        keccak256(
          encodeAbiParameters(
            [
              { name: "account", type: "address" },
              { name: "version", type: "uint256" },
            ],
            [address, version],
          ),
        ),
      );
    }

    async function deployPermissionedResolver({
      account, // deployer
      admin = account.address,
      roles = ROLES.ALL,
      ownedVersion,
      salt,
    }: {
      account: Account;
      admin?: Address;
      roles?: bigint;
      salt?: bigint;
      ownedVersion?: bigint;
    }) {
      if (typeof salt === "undefined" && typeof ownedVersion === "bigint") {
        salt = computeOwnedResolverSalt({
          address: admin,
          version: ownedVersion,
        });
      }
      return patchContractWrite(
        await deployVerifiableProxy({
          walletClient: createClient(account),
          factoryAddress: v2.VerifiableFactory.address,
          implAddress: v2.PermissionedResolverImpl.address,
          abi: v2.PermissionedResolverImpl.abi,
          functionName: "initialize",
          args: [admin, roles],
          salt,
        }),
      );
    }

    async function deployPermissionedRegistry({
      account,
      roles = ROLES.ALL,
    }: {
      account: Account;
      roles?: bigint;
    }) {
      const walletClient = createClient(account);
      const { abi, bytecode } = Artifact_PermissionedRegistry;
      const hash = await walletClient.deployContract({
        abi,
        bytecode,
        args: [
          v2.HCAFactory.address,
          v2.SimpleRegistryMetadata.address,
          account.address,
          roles,
        ],
      });
      const receipt = await waitForSuccessfulTransactionReceipt(walletClient, {
        hash,
        ensureDeployment: true,
      });
      return patchContractWrite(
        getContract({
          abi,
          address: receipt.contractAddress,
          client: walletClient,
        }),
      );
    }

    async function deployUserRegistry({
      account,
      admin = account.address,
      roles = ROLES.ALL,
      salt,
    }: {
      account: Account;
      admin?: Address;
      roles?: bigint;
      salt?: bigint;
    }) {
      return patchContractWrite(
        await deployVerifiableProxy({
          walletClient: createClient(account),
          factoryAddress: v2.VerifiableFactory.address,
          implAddress: v2.UserRegistryImpl.address,
          abi: v2.UserRegistryImpl.abi,
          functionName: "initialize",
          args: [admin, roles],
          salt,
        }),
      );
    }

    // note: TypeScript is too slow when the following is generalized to any resolver type
    async function findPermissionedRegistry({
      name,
      account = namedAccounts.deployer,
    }: {
      name: string;
      account?: Account;
    }) {
      const address = await v2.UniversalResolver.read.findExactRegistry([
        dnsEncodeName(name),
      ]);
      if (address === zeroAddress) {
        throw new Error(`expected PermissionedRegistry: ${name}`);
      }
      return patchContractWrite(
        getContract({
          abi: v2.ETHRegistry.abi,
          address,
          client: createClient(account),
        }),
      );
    }

    async function findWrapperRegistry({
      name,
      account,
    }: {
      name: string;
      account: Account;
    }) {
      const address = await v2.UniversalResolver.read.findCanonicalRegistry([
        dnsEncodeName(name),
      ]);
      if (address === zeroAddress) {
        throw new Error(`expected WrapperRegistry: ${name}`);
      }
      return patchContractWrite(
        getContract({
          abi: v2.WrapperRegistryImpl.abi,
          address,
          client: createClient(account),
        }),
      );
    }

    async function setupEnsDotEth() {
      const { resolver } = namedAccounts.owner;

      // temporary registration of "ens.eth" by deployer
      // (normally would be migrated by current ens.eth owner)
      // Deployer has REGISTRAR_ADMIN but not REGISTRAR; grant self REGISTRAR for setup
      await v2.ETHRegistry.write.grantRootRoles([
        ROLES.REGISTRY.REGISTRAR,
        namedAccounts.deployer.address,
      ]);
      // create "ens.eth" (owner gets full roles for devnet setup)
      await v2.ETHRegistry.write.register([
        "ens",
        namedAccounts.owner.address,
        zeroAddress,
        resolver.address,
        ROLES.ALL,
        MAX_EXPIRY,
      ]);

      // create "dnsname.ens.eth"
      // https://etherscan.io/address/0x08769D484a7Cd9c4A98E928D9E270221F3E8578c#code
      await setupNamedResolver(
        "dnsname",
        await deployArtifact(client, {
          file: new URL(
            "../test/integration/dns/ExtendedDNSResolver_53f64de872aad627467a34836be1e2b63713a438.json",
            import.meta.url,
          ),
        }),
      );

      // create "dnstxt.ens.eth"
      await setupNamedResolver("dnstxt", v2.DNSTXTResolver.address);

      // create "dnsalias.ens.eth"
      await setupNamedResolver("dnsalias", v2.DNSAliasResolver.address);

      function setupNamedResolver(label: string, address: Address) {
        return resolver.write.setAddr([
          namehash(`${label}.ens.eth`),
          60n,
          address,
        ]);
      }
    }

    function handleTransferError(err: unknown): never {
      // see: WrappedErrorLib.sol
      const ERROR_STRING_SELECTOR = "0x08c379a0";
      const WRAPPED_ERROR_PREFIX = stringToHex("WrappedError::0x");
      if (err instanceof ContractFunctionExecutionError) {
        if (err.cause instanceof ContractFunctionRevertedError) {
          let { raw } = err.cause;
          if (raw?.startsWith(ERROR_STRING_SELECTOR)) {
            [raw] = decodeAbiParameters([{ type: "bytes" }], slice(raw, 4));
            if (raw.startsWith(WRAPPED_ERROR_PREFIX)) {
              raw = `0x${hexToString(slice(raw, 16))}`;
            }
          }
          const abi = [
            ...v2.UnlockedMigrationController.abi,
            ...v2.LockedMigrationController.abi,
            ...v2.WrapperRegistryImpl.abi,
          ];
          const newErr = new ContractFunctionRevertedError({
            abi,
            data: raw,
            functionName: err.functionName,
          });
          if (newErr.data) {
            throw new ContractFunctionExecutionError(newErr, err);
          }
        }
      }
      throw err;
    }
  } catch (err) {
    await shutdown();
    throw err;
  } finally {
    unquiet();
  }
}
