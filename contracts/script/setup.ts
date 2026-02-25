import { artifacts } from "@rocketh";
import { rm } from "node:fs/promises";
import { anvil as createAnvil } from "prool/instances";
import { type Environment, executeDeployScripts, resolveConfig } from "rocketh";
import {
  type Abi,
  type Account,
  type Address,
  type Chain,
  createWalletClient,
  getContract,
  type GetContractReturnType,
  type Hash,
  type Hex,
  namehash,
  publicActions,
  testActions,
  type Transport,
  webSocket,
  zeroAddress,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";

import { deployArtifact } from "../test/integration/fixtures/deployArtifact.js";
import {
  computeVerifiableProxyAddress,
  deployVerifiableProxy,
} from "../test/integration/fixtures/deployVerifiableProxy.js";
import { waitForSuccessfulTransactionReceipt } from "../test/utils/waitForSuccessfulTransactionReceipt.ts";
import {
  LOCAL_BATCH_GATEWAY_URL,
  MAX_EXPIRY,
  ROLES,
} from "./deploy-constants.js";
import { patchArtifactsV1 } from "./patchArtifactsV1.js";

/**
 * Default chain ID for devnet environment
 */
export const DEFAULT_CHAIN_ID = 0xeeeeed;

type DeployedArtifacts = Record<string, Abi>;

type Future<T> = T | Promise<T>;

// typescript key (see below) mapped to rocketh deploy name
const renames: Record<string, string> = {
  ETHRegistrarV1: "BaseRegistrarImplementation",
};

const contracts = {
  SimpleRegistryMetadata: artifacts.SimpleRegistryMetadata.abi,
  HCAFactory: artifacts.MockHCAFactoryBasic.abi,
  VerifiableFactory: artifacts.VerifiableFactory.abi,
  OwnedResolverV2:
    artifacts["src/resolver/OwnedResolver.sol/OwnedResolver"].abi,
  UserRegistry: artifacts.UserRegistry.abi,
  ETHRegistry: artifacts.PermissionedRegistry.abi,
  ETHRegistrar: artifacts.ETHRegistrar.abi,
  StandardRentPriceOracle: artifacts.StandardRentPriceOracle.abi,
  MockUSDC: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
  MockDAI: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
  // v1
  BatchGatewayProvider: artifacts.GatewayProvider.abi,
  RootV1: artifacts.Root.abi,
  ENSRegistryV1: artifacts.ENSRegistry.abi,
  ETHRegistrarV1: artifacts.BaseRegistrarImplementation.abi,
  ReverseRegistrarV1: artifacts.ReverseRegistrar.abi,
  PublicResolverV1: artifacts.PublicResolver.abi,
  NameWrapperV1: artifacts.NameWrapper.abi,
  UniversalResolverV1: artifacts.UniversalResolver.abi,
  // v1 compat
  DefaultReverseRegistrar: artifacts.DefaultReverseRegistrar.abi,
  DefaultReverseResolver: artifacts.DefaultReverseResolver.abi,
  //
  MigratedWrappedNameRegistryImpl: artifacts.MigratedWrappedNameRegistry.abi,
  //
  UniversalResolverV2: artifacts.UniversalResolverV2.abi,
  RootRegistry: artifacts.PermissionedRegistry.abi,
  // TODO: update to actual reverse registrar when we have it
  ETHReverseRegistrar: artifacts['lib/ens-contracts/contracts/reverseRegistrar/L2ReverseRegistrar.sol/L2ReverseRegistrar'].abi,
  ETHReverseResolver: artifacts.ETHReverseResolver.abi,
  DNSTLDResolver: artifacts.DNSTLDResolver.abi,
  DNSTXTResolver: artifacts.DNSTXTResolver.abi,
  DNSAliasResolver: artifacts.DNSAliasResolver.abi,
} as const satisfies DeployedArtifacts;

export type StateSnapshot = () => Promise<void>;
export type DevnetClient = ReturnType<typeof createClient>;
export type DevnetEnvironment = Awaited<ReturnType<typeof setupDevnet>>;

export type Deployment = DeploymentInstance<typeof contracts>;

function ansi(c: any, s: any) {
  return `\x1b[${c}m${s}\x1b[0m`;
}

function createClient(transport: Transport, chain: Chain, account: Account) {
  return createWalletClient({
    transport,
    chain,
    account,
    pollingInterval: 50,
    cacheTime: 0, // must be 0 due to client caching
  })
    .extend(publicActions)
    .extend(testActions({ mode: "anvil" }));
}

type ContractsOf<A> = {
  [K in keyof A]: A[K] extends Abi | readonly unknown[]
    ? GetContractReturnType<A[K], DevnetClient>
    : never;
};

export class DeploymentInstance<
  const A extends DeployedArtifacts = typeof contracts,
> {
  readonly contracts: ContractsOf<A>;
  constructor(
    readonly anvil: ReturnType<typeof createAnvil>,
    readonly client: DevnetClient,
    readonly transport: Transport,
    readonly hostPort: string,
    readonly env: Environment,
    namedArtifacts: A,
  ) {
    this.contracts = Object.fromEntries(
      Object.entries(namedArtifacts).map(([name, abi]) => {
        const deployment = env.get(renames[name] ?? name.replace(/V1$/, ""));
        const contract = getContract({
          abi,
          address: deployment.address,
          client,
        }) as {
          write?: Record<string, (...parameters: unknown[]) => Promise<Hash>>;
        } & Record<string, unknown>;
        if ("write" in contract) {
          const write = contract.write!;
          // override to ensure successful transaction
          // otherwise, success is being assumed based on an eth_estimateGas call
          // but state could change, or eth_estimateGas could be wrong
          contract.write = new Proxy(
            {},
            {
              get(_, functionName: string) {
                return async (...parameters: unknown[]) => {
                  const hash = await write[functionName](...parameters);
                  await waitForSuccessfulTransactionReceipt(client, { hash });
                  return hash;
                };
              },
            },
          );
        }
        return [name, contract];
      }),
    ) as ContractsOf<A>;
  }
  async computeVerifiableProxyAddress(args: {
    deployer: Address;
    salt: bigint;
  }) {
    return computeVerifiableProxyAddress({
      factoryAddress: this.contracts.VerifiableFactory.address,
      bytecode: artifacts["UUPSProxy"].bytecode,
      ...args,
    });
  }
  async deployPermissionedRegistry({
    account,
    roles = ROLES.ALL,
  }: {
    account: Account;
    roles?: bigint;
  }) {
    const walletClient = createClient(
      this.transport,
      this.client.chain,
      account,
    );
    const { abi, bytecode } = artifacts.PermissionedRegistry;
    const hash = await walletClient.deployContract({
      abi,
      bytecode,
      args: [
        this.contracts.HCAFactory.address,
        this.contracts.SimpleRegistryMetadata.address,
        account.address,
        roles,
      ],
    });
    const receipt = await waitForSuccessfulTransactionReceipt(walletClient, {
      hash,
      ensureDeployment: true,
    });
    return getContract({
      abi,
      address: receipt.contractAddress,
      client: walletClient,
    });
  }
  async deployOwnedResolver({
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
    return deployVerifiableProxy({
      walletClient: createClient(this.transport, this.client.chain, account),
      factoryAddress: this.contracts.VerifiableFactory.address,
      implAddress: this.contracts.OwnedResolverV2.address,
      abi: this.contracts.OwnedResolverV2.abi,
      functionName: "initialize",
      args: [admin, roles],
      salt,
    });
  }
  deployUserRegistry({
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
    return deployVerifiableProxy({
      walletClient: createClient(this.transport, this.client.chain, account),
      factoryAddress: this.contracts.VerifiableFactory.address,
      implAddress: this.contracts.UserRegistry.address,
      abi: this.contracts.UserRegistry.abi,
      functionName: "initialize",
      args: [admin, roles],
      salt,
    });
  }
}

export async function setupDevnet({
  chainId = DEFAULT_CHAIN_ID,
  port = 0,
  extraAccounts = 5,
  mnemonic = "test test test test test test test test test test test junk",
  saveDeployments = false,
  quiet = !saveDeployments,
  procLog = false,
  extraTime = 0,
}: {
  chainId?: number;
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
    const names = ["deployer", "owner", "bridger", "user", "user2"];
    extraAccounts += names.length;

    process.env["RUST_LOG"] = "info"; // required to capture console.log()
    const baseArgs = {
      accounts: extraAccounts,
      mnemonic,
      ...(extraTime
        ? { timestamp: Math.floor(Date.now() / 1000) - extraTime }
        : {}),
    };
    const anvilInstance = createAnvil({
      ...baseArgs,
      chainId,
      port,
    });

    const accounts = Array.from({ length: extraAccounts }, (_, i) =>
      Object.assign(mnemonicToAccount(mnemonic, { addressIndex: i }), {
        name: names[i] ?? `unnamed${i}`,
      }),
    );
    const namedAccounts = Object.fromEntries(accounts.map((x) => [x.name, x]));
    const { deployer } = namedAccounts;

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
            return showConsole ? `Devnet ${line}` : []; // ignore console during gas estimation
          }
        }
        if (!procLog) return [];
        return ansi(36, `Devnet ${line}`);
      });
      if (!lines.length) return;
      console.log(lines.join("\n"));
    };
    anvilInstance.on("message", log);
    finalizers.push(() => anvilInstance.off("message", log));

    const transportOptions = {
      retryCount: 1,
      keepAlive: true,
      reconnect: false,
      timeout: 10000,
    } as const;
    const transport = webSocket(`ws://${hostPort}`, transportOptions);

    const nativeCurrency = {
      name: "Ether",
      symbol: "ETH",
      decimals: 18,
    } as const;
    const chain: Chain = {
      id: chainId,
      name: "Devnet",
      nativeCurrency,
      rpcUrls: { default: { http: [`http://${hostPort}`] } },
    };

    const client = createClient(transport, chain, deployer);

    console.log("Deploying contracts");
    const name = "devnet-local";
    if (saveDeployments) {
      await rm(new URL(`../deployments/${name}`, import.meta.url), {
        recursive: true,
        force: true,
      });
    }
    process.env.BATCH_GATEWAY_URLS = JSON.stringify([LOCAL_BATCH_GATEWAY_URL]);
    const deployResult = await executeDeployScripts(
      resolveConfig({
        network: {
          nodeUrl: chain.rpcUrls.default.http[0],
          name,
          tags: [
            "l1",
            "local",
            "use_root", // deploy root contracts
            "allow_unsafe", // state hacks
            "legacy", // legacy registry
          ],
          fork: false,
          scripts: ["lib/ens-contracts/deploy", "deploy"],
          publicInfo: {
            name,
            nativeCurrency: chain.nativeCurrency,
            rpcUrls: { default: { http: [...chain.rpcUrls.default.http] } },
          },
          pollingInterval: 0.001, // cannot be zero
        },
        askBeforeProceeding: false,
        saveDeployments,
        accounts: Object.fromEntries(accounts.map((x) => [x.name, x.address])),
      }),
    );

    const deployment = new DeploymentInstance(
      anvilInstance,
      client,
      transport,
      hostPort,
      deployResult,
      contracts,
    );

    await setupEnsDotEth(deployment, deployer);
    console.log("Setup ens.eth");

    console.log("Deployed ENSv2");
    return {
      accounts,
      namedAccounts,
      deployment,
      sync,
      waitFor,
      getBlock,
      saveState,
      shutdown,
    };

    async function waitFor(hash: Future<Hex>) {
      hash = await hash;
      const receipt = await waitForSuccessfulTransactionReceipt(client, {
        hash,
      });
      return { receipt, deployment };
    }
    function getBlock() {
      return client.getBlock();
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
      const block = await getBlock();
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
  } catch (err) {
    await shutdown();
    throw err;
  } finally {
    unquiet();
  }
}

async function setupEnsDotEth(deployment: Deployment, account: Account) {
  // create registry for "ens.eth"
  // const ens_ethRegistry = await deployment.deployPermissionedRegistry({
  //   account,
  // });

  // created owned resolver for "ens.eth"
  const resolver = await deployment.deployOwnedResolver({ account });

  // create "ens.eth"
  await deployment.contracts.ETHRegistry.write.register([
    "ens",
    account.address,
    zeroAddress, //ens_ethRegistry.address,
    resolver.address,
    0n,
    MAX_EXPIRY,
  ]);

  // create "dnsname.ens.eth"
  // https://etherscan.io/address/0x08769D484a7Cd9c4A98E928D9E270221F3E8578c#code
  await setupNamedResolver(
    "dnsname",
    await deployArtifact(deployment.client, {
      file: new URL(
        "../test/integration/l1/dns/ExtendedDNSResolver_53f64de872aad627467a34836be1e2b63713a438.json",
        import.meta.url,
      ),
    }),
  );

  // create "dnstxt.ens.eth"
  await setupNamedResolver(
    "dnstxt",
    deployment.contracts.DNSTXTResolver.address,
  );

  // create "dnsalias.ens.eth"
  await setupNamedResolver(
    "dnsalias",
    deployment.contracts.DNSAliasResolver.address,
  );

  async function setupNamedResolver(label: string, address: Address) {
    await resolver.write.setAddr([namehash(`${label}.ens.eth`), 60n, address]);
    // await ens_ethRegistry.write.register([
    //   label,
    //   account.address,
    //   zeroAddress,
    //   resolver.address,
    //   0n,
    //   MAX_EXPIRY,
    // ]);
  }
}
