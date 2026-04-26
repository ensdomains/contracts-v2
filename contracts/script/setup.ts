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
  http,
  zeroAddress,
} from "viem";
import { mainnet } from "viem/chains";
import { mnemonicToAccount } from "viem/accounts";

import {
  computeVerifiableProxyAddress as computeVerifiableProxyAddress_,
  deployVerifiableProxy,
} from "../test/integration/fixtures/deployVerifiableProxy.js";
import { dnsEncodeName, splitName } from "../test/utils/utils.js";
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

    const transport = http(`http://${hostPort}`, {
      retryCount: 1,
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
        // TODO: update to actual reverse registrar when we have it
        abi: artifacts[
          "lib/ens-contracts/contracts/reverseRegistrar/L2ReverseRegistrar.sol/L2ReverseRegistrar"
        ].abi,
        address: rocketh.get("ETHReverseRegistrar").address,
        client,
      }),
      ETHReverseResolver: getContract({
        abi: artifacts.ETHReverseResolver.abi,
        address: rocketh.get("ETHReverseResolver").address,
        client,
      }),
      Graveyard: getContract({
        abi: artifacts.Graveyard.abi,
        address: rocketh.get("Graveyard").address,
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
      RegistrarSecurityController: getContract({
        abi: artifacts.RegistrarSecurityController.abi,
        address: rocketh.get("RegistrarSecurityController").address,
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

    const erc20 = {
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
    };

    [shared, v1, v2, erc20]
      .flatMap((x) => Object.values(x))
      .forEach(patchContractWrite);
    console.log("Linked contracts");

    const namedAccounts = Object.fromEntries(
      await Promise.all(
        accounts.map(async (account) => {
          const resolver = await deployPermissionedResolver({
            account,
            salt: { ownedVersion: 0n },
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
      erc20,
      sync,
      waitFor,
      saveState,
      shutdown,
      createClient,
      computeVerifiableProxyAddress,
      computeUserRegistrySalt,
      computeOwnedResolverSalt,
      castUserRegistry,
      castPermissionedResolver,
      deployUserRegistry,
      deployPermissionedResolver,
      findPermissionedRegistry,
      findWrapperRegistry,
      patchContractWrite,
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

    function computeVerifiableProxyAddress(deployer: Address, salt: bigint) {
      return computeVerifiableProxyAddress_({
        factoryAddress: v2.VerifiableFactory.address,
        bytecode: artifacts["UUPSProxy"].bytecode,
        deployer,
        salt,
      });
    }

    function computeOwnedResolverSalt(owner: Address, version = 0n) {
      return BigInt(
        keccak256(
          encodeAbiParameters(
            [
              { name: "id", type: "bytes32" },
              { name: "owner", type: "address" },
              { name: "version", type: "uint256" },
            ],
            [keccak256(stringToHex("OwnedResolver")), owner, version],
          ),
        ),
      );
    }

    function computeUserRegistrySalt(name: string, version = 0n) {
      return BigInt(
        keccak256(
          encodeAbiParameters(
            [
              { name: "id", type: "bytes32" },
              { name: "node", type: "bytes32" },
              { name: "version", type: "uint256" },
            ],
            [keccak256(stringToHex("UserRegistry")), namehash(name), version],
          ),
        ),
      );
    }

    async function deployPermissionedResolver({
      account, // deployer
      admin = account.address,
      roles = ROLES.ALL,
      salt,
    }: {
      account: Account;
      admin?: Address;
      roles?: bigint;
      salt?: bigint | { ownedVersion: bigint };
    }) {
      if (typeof salt === "object") {
        salt = computeOwnedResolverSalt(admin, salt.ownedVersion);
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

    async function deployUserRegistry({
      account,
      admin = account.address,
      roles = ROLES.ALL,
      salt,
    }: {
      account: Account;
      admin?: Address;
      roles?: bigint;
      salt?: bigint | { name: string; version?: bigint };
    }) {
      const implAddress = v2.UserRegistryImpl.address;
      if (typeof salt === "object") {
        salt = computeUserRegistrySalt(salt.name, salt.version);
      }
      return patchContractWrite(
        await deployVerifiableProxy({
          walletClient: createClient(account),
          factoryAddress: v2.VerifiableFactory.address,
          implAddress,
          abi: v2.UserRegistryImpl.abi,
          functionName: "initialize",
          args: [admin, roles],
          salt,
        }),
      );
    }

    function castUserRegistry(
      address: Address,
      account: Account = namedAccounts.deployer,
    ) {
      return patchContractWrite(
        getContract({
          abi: v2.UserRegistryImpl.abi,
          address,
          client: createClient(account),
        }),
      );
    }

    function castPermissionedResolver(
      address: Address,
      account: Account = namedAccounts.deployer,
    ) {
      return patchContractWrite(
        getContract({
          abi: v2.PermissionedResolverImpl.abi,
          address,
          client: createClient(account),
        }),
      );
    }

    // note: casts to UserRegistry even if PermissionRegistry
    // note: TypeScript is too slow when the following is generalized to any resolver type
    async function findPermissionedRegistry(name: string, account?: Account) {
      const address = await v2.UniversalResolver.read.findExactRegistry([
        dnsEncodeName(name),
      ]);
      if (address === zeroAddress) {
        throw new Error(`expected PermissionedRegistry: ${name}`);
      }
      // TODO: do a supportsInterface check?
      return castUserRegistry(address, account);
    }

    function computeWrapperRegistryAddress(name: string) {
      const labels = splitName(name);
      let currentName = labels.pop();
      if (currentName !== "eth" || !labels.length) {
        throw new Error(`expected .eth 2LD+: ${name}`);
      }
      let address = v2.LockedMigrationController.address;
      while (labels.length) {
        currentName = `${labels.pop()}.${currentName}`;
        address = computeVerifiableProxyAddress(
          address,
          BigInt(namehash(currentName)),
        );
      }
      return address;
    }

    function findWrapperRegistry(
      name: string,
      account: Account = namedAccounts.deployer,
    ) {
      const address = computeWrapperRegistryAddress(name);
      // this may not be deployed yet
      // this is equivalent to `findExactRegistry()` when deployed
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
