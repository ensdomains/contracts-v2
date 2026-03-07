import { artifacts } from "@rocketh";
import { rm } from "node:fs/promises";
import { anvil as createAnvil } from "prool/instances";
import { executeDeployScripts, resolveConfig } from "rocketh";
import {
  type Account,
  type Address,
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  createWalletClient,
  decodeAbiParameters,
  getContract,
  type Hex,
  hexToString,
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

import {
  LOCAL_BATCH_GATEWAY_URL,
  MAX_EXPIRY,
  ROLES,
} from "./deploy-constants.js";
import { deployArtifact } from "../test/integration/fixtures/deployArtifact.js";
import {
  computeVerifiableProxyAddress,
  deployVerifiableProxy,
} from "../test/integration/fixtures/deployVerifiableProxy.js";
import { waitForSuccessfulTransactionReceipt } from "../test/utils/waitForSuccessfulTransactionReceipt.js";
import { patchArtifactsV1 } from "./patchArtifactsV1.js";
import { dnsEncodeName } from "../test/utils/utils.js";

const NAMED_ACCOUNTS = ["deployer", "owner", "user", "user2"] as const;

export type StateSnapshot = () => Promise<void>;
export type DevnetEnvironment = Awaited<ReturnType<typeof setupDevnet>>;

function ansi(c: any, s: any) {
  return `\x1b[${c}m${s}\x1b[0m`;
}

export async function setupDevnet({
  port = 0,
  extraAccounts = 5,
  mnemonic = "test test test test test test test test test test test junk",
  saveDeployments = false,
  quiet = !saveDeployments,
  procLog = false,
  extraTime = 0,
}: {
  port?: number;
  extraAccounts?: number;
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

    // list of named wallets
    extraAccounts += NAMED_ACCOUNTS.length;

    process.env["RUST_LOG"] = "info"; // required to capture console.log()
    const anvilInstance = createAnvil({
      accounts: extraAccounts,
      mnemonic,
      chainId: mainnet.id,
      port,
      ...(extraTime
        ? { timestamp: Math.floor(Date.now() / 1000) - extraTime }
        : {}),
    });

    const accounts = Array.from({ length: extraAccounts }, (_, i) =>
      Object.assign(mnemonicToAccount(mnemonic, { addressIndex: i }), {
        name: NAMED_ACCOUNTS[i] ?? `unnamed${i}`,
      }),
    );
    const namedAccounts = Object.fromEntries(
      accounts.map((x) => [x.name, x]),
    ) as Record<(typeof NAMED_ACCOUNTS)[number], (typeof accounts)[number]>;

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

    const client = createClient(namedAccounts.deployer);

    console.log("Deploying contracts");
    const deploymentName = "devnet-local";
    if (saveDeployments) {
      await rm(new URL(`../deployments/${deploymentName}`, import.meta.url), {
        recursive: true,
        force: true,
      });
    }
    process.env.BATCH_GATEWAY_URLS = JSON.stringify([LOCAL_BATCH_GATEWAY_URL]);
    const rocketh = await executeDeployScripts(
      resolveConfig({
        network: {
          nodeUrl: `http://${hostPort}`,
          name: deploymentName,
          tags: [
            "v2",
            "local",
            "use_root", // deploy root contracts
            "allow_unsafe", // state hacks
            "legacy", // legacy registry
          ],
          fork: false,
          scripts: ["lib/ens-contracts/deploy", "deploy"],
          pollingInterval: 0.001, // cannot be zero
        },
        askBeforeProceeding: false,
        saveDeployments,
        accounts: Object.fromEntries(accounts.map((x) => [x.name, x.address])),
      }),
    );
    console.log("Deployed contracts");

    // note: TypeScript is too slow when the following is generalized
    const shared = {
      BatchGatewayProvider: getContract({
        abi: artifacts.GatewayProvider.abi,
        address: rocketh.get("BatchGatewayProvider").address,
        client,
      }),
      DefaultReverseRegistrar: getContract({
        abi: artifacts.DefaultReverseRegistrar.abi,
        address: rocketh.get("DefaultReverseRegistrar").address,
        client,
      }),
      DefaultReverseResolver: getContract({
        abi: artifacts.DefaultReverseResolver.abi,
        address: rocketh.get("DefaultReverseResolver").address,
        client,
      }),
      ETHReverseRegistrar: getContract({
        abi: artifacts.L2ReverseRegistrar.abi,
        address: rocketh.get("ETHReverseRegistrar").address,
        client,
      }), // TODO: change to using v1
      ETHReverseResolver: getContract({
        abi: artifacts.ETHReverseResolver.abi,
        address: rocketh.get("ETHReverseResolver").address,
        client,
      }),
    };

    const v1 = {
      Root: getContract({
        abi: artifacts.Root.abi,
        address: rocketh.get("Root").address,
        client,
      }),
      ENSRegistry: getContract({
        abi: artifacts.ENSRegistry.abi,
        address: rocketh.get("ENSRegistry").address,
        client,
      }),
      BaseRegistrar: getContract({
        abi: artifacts.BaseRegistrarImplementation.abi,
        address: rocketh.get("BaseRegistrarImplementation").address,
        client,
      }),
      ReverseRegistrar: getContract({
        abi: artifacts.ReverseRegistrar.abi,
        address: rocketh.get("ReverseRegistrar").address,
        client,
      }),
      NameWrapper: getContract({
        abi: artifacts.NameWrapper.abi,
        address: rocketh.get("NameWrapper").address,
        client,
      }),
      // resolvers
      PublicResolver: getContract({
        abi: artifacts.PublicResolver.abi,
        address: rocketh.get("PublicResolver").address,
        client,
      }),
      UniversalResolver: getContract({
        abi: artifacts.UniversalResolver.abi,
        address: rocketh.get("UniversalResolver").address,
        client,
      }),
    };

    const v2 = {
      SimpleRegistryMetadata: getContract({
        abi: artifacts.SimpleRegistryMetadata.abi,
        address: rocketh.get("SimpleRegistryMetadata").address,
        client,
      }),
      HCAFactory: getContract({
        abi: artifacts.MockHCAFactoryBasic.abi,
        address: rocketh.get("HCAFactory").address,
        client,
      }),
      VerifiableFactory: getContract({
        abi: artifacts.VerifiableFactory.abi,
        address: rocketh.get("VerifiableFactory").address,
        client,
      }),
      RootRegistry: getContract({
        abi: artifacts.PermissionedRegistry.abi,
        address: rocketh.get("RootRegistry").address,
        client,
      }),
      ETHRegistry: getContract({
        abi: artifacts.PermissionedRegistry.abi,
        address: rocketh.get("ETHRegistry").address,
        client,
      }),
      // eth registrar
      ETHRegistrar: getContract({
        abi: artifacts.ETHRegistrar.abi,
        address: rocketh.get("ETHRegistrar").address,
        client,
      }),
      StandardRentPriceOracle: getContract({
        abi: artifacts.StandardRentPriceOracle.abi,
        address: rocketh.get("StandardRentPriceOracle").address,
        client,
      }),
      MockUSDC: getContract({
        abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
        address: rocketh.get("MockUSDC").address,
        client,
      }),
      MockDAI: getContract({
        abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
        address: rocketh.get("MockDAI").address,
        client,
      }),
      // VerifiableFactory implementations
      PermissionedResolverImpl: getContract({
        abi: artifacts.PermissionedResolver.abi,
        address: rocketh.get("PermissionedResolverImpl").address,
        client,
      }),
      UserRegistryImpl: getContract({
        abi: artifacts.UserRegistry.abi,
        address: rocketh.get("UserRegistryImpl").address,
        client,
      }),
      WrapperRegistryImpl: getContract({
        abi: artifacts.WrapperRegistry.abi,
        address: rocketh.get("WrapperRegistryImpl").address,
        client,
      }),
      // migration
      UnlockedMigrationController: getContract({
        abi: artifacts.UnlockedMigrationController.abi,
        address: rocketh.get("UnlockedMigrationController").address,
        client,
      }),
      LockedMigrationController: getContract({
        abi: artifacts.LockedMigrationController.abi,
        address: rocketh.get("LockedMigrationController").address,
        client,
      }),
      // resolvers
      UniversalResolver: getContract({
        abi: artifacts.UniversalResolverV2.abi,
        address: rocketh.get("UniversalResolverV2").address,
        client,
      }),
      DNSTLDResolver: getContract({
        abi: artifacts.DNSTLDResolver.abi,
        address: rocketh.get("DNSTLDResolver").address,
        client,
      }),
      DNSTXTResolver: getContract({
        abi: artifacts.DNSTXTResolver.abi,
        address: rocketh.get("DNSTXTResolver").address,
        client,
      }),
      DNSAliasResolver: getContract({
        abi: artifacts.DNSAliasResolver.abi,
        address: rocketh.get("DNSAliasResolver").address,
        client,
      }),
      ENSV1Resolver: getContract({
        abi: artifacts.ENSV1Resolver.abi,
        address: rocketh.get("ENSV1Resolver").address,
        client,
      }),
      ENSV2Resolver: getContract({
        abi: artifacts.ENSV2Resolver.abi,
        address: rocketh.get("ENSV2Resolver").address,
        client,
      }),
    };

    [shared, v1, v2]
      .flatMap((x) => Object.values(x))
      .forEach(patchContractWrite);
    console.log("Linked contracts");

    const resolvers = Object.fromEntries(
      await Promise.all(
        NAMED_ACCOUNTS.map(async (name, i) => {
          return [
            name,
            await deployPermissionedResolver({ account: accounts[i] }),
          ];
        }),
      ),
    ) as Record<
      (typeof NAMED_ACCOUNTS)[number],
      Awaited<ReturnType<typeof deployPermissionedResolver>>
    >;
    console.log("Created PermissionedResolvers");

    await setupEnsDotEth();
    console.log("Setup ens.eth");

    console.log("Deployed ENSv2");
    return {
      client,
      createClient,
      hostPort,
      accounts,
      namedAccounts,
      resolvers,
      rocketh,
      shared,
      v1,
      v2,
      sync,
      waitFor,
      saveState,
      shutdown,
      verifiableProxyAddress,
      deployPermissionedRegistry,
      deployPermissionedResolver,
      deployUserRegistry,
      patchContractWrite,
      unwrapError,
      findPermissionedRegistry,
      findWrapperRegistry,
    };

    async function waitFor(hash: Hex | Promise<Hex>) {
      return waitForSuccessfulTransactionReceipt(client, {
        hash: await hash,
      });
    }

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
                const receipt = await waitFor(
                  write0[functionName](...parameters),
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
        bytecode: artifacts["UUPSProxy"].bytecode,
        ...args,
      });
    }

    async function deployPermissionedResolver({
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
      const { abi, bytecode } = artifacts.PermissionedRegistry;
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
      const address = await v2.UniversalResolver.read.findRegistry([
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
      const resolver = resolvers.owner;

      // hack register "ens.eth"
      await v2.ETHRegistry.write.register([
        "ens",
        namedAccounts.owner.address,
        zeroAddress,
        resolver.address,
        0n,
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

    function unwrapError(err: unknown): never {
      // see: WrappedErrorLib.sol
      const ERROR_STRING_SELECTOR = "0x08c379a0";
      const WRAPPED_ERROR_PREFIX = stringToHex("WrappedError::0x");
      if (err instanceof ContractFunctionExecutionError) {
        if (err.cause instanceof ContractFunctionRevertedError) {
          let { raw } = err.cause;
          if (raw?.startsWith(ERROR_STRING_SELECTOR)) {
            [raw] = decodeAbiParameters([{ type: "bytes" }], slice(raw, 4));
            if (raw.startsWith(WRAPPED_ERROR_PREFIX)) {
              const abi = [
                ...v2.UnlockedMigrationController.abi,
                ...v2.LockedMigrationController.abi,
                ...v2.WrapperRegistryImpl.abi,
                ...artifacts.LibMigration.abi,
              ];
              const newErr = new ContractFunctionRevertedError({
                abi,
                data: `0x${hexToString(slice(raw, 16))}`,
                functionName: err.functionName,
              });
              if (newErr.data) {
                throw new ContractFunctionExecutionError(newErr, err);
              }
            }
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
