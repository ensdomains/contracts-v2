import { readFile, readdir } from "node:fs/promises";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { join, relative } from "node:path";
import {
  Chain,
  encodeFunctionData,
  type TransactionRequest,
  zeroAddress,
  type Address,
  createPublicClient,
  http,
} from "viem";
import { readContract } from "viem/actions";
import { mainnet, sepolia } from "viem/chains";
import { normalize } from "viem/ens";
import { Abi_VerifiableFactory } from "generated/abis/VerifiableFactory.js";
import { Abi_PermissionedResolver } from "generated/abis/PermissionedResolver.js";
import { Abi_NameWrapper } from "generated/abis/NameWrapper.js";
import { Abi_BaseRegistrarImplementation } from "generated/abis/BaseRegistrarImplementation.js";
import { Abi_ReverseRegistrarAdapter } from "generated/abis/ReverseRegistrarAdapter.js";
import { Abi_ENSRegistry } from "generated/abis/ENSRegistry.js";
import { computeOwnedResolverSalt } from "./salts.js";
import { ROLES } from "./deploy-constants.js";
import { computeVerifiableProxyAddress } from "../test/integration/fixtures/deployVerifiableProxy.js";
import {
  COIN_TYPE_ETH,
  dnsEncodeName,
  getReverseName,
  labelhash,
  namehash,
} from "../test/utils/utils.js";
import { encodeMigrationData } from "../test/utils/migrationData.js";

// the profiles need stored in a resolver
// in v1, the records were in the PublicResolver
// in v2, we need a PermissionedResolver for "ens.eth"

// ens.eth should be migrated to v1
// but the new resolver will work in either v1 or v2

// all v2 contract primary names are claimable via owner (dao)
// so after new deployment, the first operation is for owner
// to claim every contract and update the name and resolver

const KNOWN_CONTRACT_COLLISIONS = new Set(["MigrationHelper"]);

const CLAIMS = [
  "ReverseClaimer",
  "Ownable",
  "IContractNamer",
  "DelegatedContractNamer",
] as const;

export type ContractInfo = {
  deployment: string;
  name: string;
  claim?: (typeof CLAIMS)[number];
};

export type DeployedContractInfo = ContractInfo & { address: Address };

export type Deployments = Record<string, Address>;

export type NamingInfo = {
  label: string;
  v1Owner: Address;
  isWrapped: boolean;
  v2Owner: Address;
  resolverSaltVersion?: bigint;
  wallets: Record<Address, string>;
  managers: Address[];
  chain: Chain;
  publicRPC?: string;
};

export async function getContractNames() {
  const unique = new Set<string>();
  const names = JSON.parse(
    await readFile(new URL("../docs/contractNames.json", import.meta.url), {
      encoding: "utf8",
    }),
  );
  if (!Array.isArray(names)) {
    throw new Error("expected array");
  }
  return names
    .map((json: ContractInfo) => {
      try {
        if (typeof json !== "object") {
          throw new Error("not object");
        } else if (typeof json.deployment !== "string") {
          throw new Error("invalid deployment");
        } else if (normalize(json.name) !== json.name) {
          throw new Error("invalid name");
        } else if (unique.has(json.name)) {
          throw new Error("duplicate name");
        } else if (unique.has(json.deployment)) {
          throw new Error("duplicate deployment");
        } else if (
          typeof json.claim !== "undefined" &&
          !CLAIMS.includes(json.claim)
        ) {
          throw new Error("invalid method");
        }
        unique.add(json.name);
        unique.add(json.deployment);
        return json;
      } catch (cause) {
        throw new Error(`invalid contract name: ${JSON.stringify(json)}`, {
          cause,
        });
      }
    })
    .sort((a, b) => {
      let c = CLAIMS.indexOf(a.claim!) - CLAIMS.indexOf(b.claim!);
      if (!c) c = a.deployment.localeCompare(b.deployment);
      return c;
    });
}

async function readDeploymentChainId(dir: string): Promise<number> {
  try {
    const json = JSON.parse(await readFile(join(dir, ".chain"), "utf8"));
    const chainId = parseInt(json.chainId);
    if (!Number.isInteger(chainId)) {
      throw new Error("expected number");
    }
    return chainId;
  } catch (cause) {
    throw new Error("deployment missing chainId", { cause });
  }
}

async function readDeploymentAddresses(
  dir: string,
  v1 = false,
): Promise<Deployments> {
  const suffix = ".json";
  const addresses = Object.fromEntries(
    await Promise.all(
      (await readdir(dir))
        .filter((x) => x.endsWith(suffix) && !x.startsWith("."))
        .sort()
        .map(async (name) => {
          const json = JSON.parse(await readFile(join(dir, name), "utf8"));
          let slug = name.slice(0, -suffix.length);
          if (v1 && KNOWN_CONTRACT_COLLISIONS.has(slug)) {
            slug += "Old";
          }
          return [slug, json.address as Address];
        }),
    ),
  );
  if (!addresses[v1 ? "ENSRegistry" : "RootRegistry"]) {
    throw new Error(`invalid deployment: ${dir}`);
  }
  return addresses;
}

export function createDeployResolverTransaction({
  info,
  v2,
}: {
  info: NamingInfo;
  v2: Deployments;
}): TransactionRequest {
  const managerRoles = ROLES.REGULAR & ~ROLES.RESOLVER.UPGRADE; // ?
  const initData = encodeFunctionData({
    abi: Abi_PermissionedResolver,
    functionName: "initialize",
    args: [
      [
        { account: info.v2Owner, roleBitmap: ROLES.ALL },
        ...info.managers.map((account) => ({
          account,
          roleBitmap: managerRoles,
        })),
      ],
      [],
    ],
  });
  return {
    to: v2.VerifiableFactory,
    data: encodeFunctionData({
      abi: Abi_VerifiableFactory,
      functionName: "deployProxy",
      args: [
        v2.PermissionedResolverImpl,
        computeOwnedResolverSalt(info.v2Owner, info.resolverSaltVersion),
        initData,
      ],
    }),
  };
}

export function expectedResolverAddress({
  info,
  v2,
}: {
  info: NamingInfo;
  v2: Deployments;
}): Address {
  return computeVerifiableProxyAddress({
    factoryAddress: v2.VerifiableFactory,
    deployer: info.v2Owner,
    salt: computeOwnedResolverSalt(info.v2Owner, info.resolverSaltVersion),
  });
}

export function createMigrationTransaction({
  info,
  v1,
  v2,
}: {
  info: NamingInfo;
  v1: Deployments;
  v2: Deployments;
}): TransactionRequest {
  const resolver = expectedResolverAddress({ info, v2 });
  const migrationData = encodeMigrationData({
    label: info.label,
    owner: info.v2Owner,
    resolver,
    subregistry: zeroAddress,
  });
  return info.isWrapped
    ? {
        to: v1.NameWrapper,
        data: encodeFunctionData({
          abi: Abi_NameWrapper,
          functionName: "safeTransferFrom",
          args: [
            info.v2Owner,
            v2.UnlockedMigrationController,
            BigInt(namehash(`${info.label}.eth`)),
            1n,
            migrationData,
          ],
        }),
      }
    : {
        to: v1.BaseRegistrarImplementation,
        data: encodeFunctionData({
          abi: Abi_BaseRegistrarImplementation,
          functionName: "safeTransferFrom",
          args: [
            info.v2Owner,
            v2.UnlockedMigrationController,
            BigInt(labelhash(info.label)),
            migrationData,
          ],
        }),
      };
}

export function createReverseRegistrarTransactions({
  info,
  v1,
  v2,
  names,
}: {
  info: NamingInfo;
  v1: Deployments;
  v2: Deployments;
  names: DeployedContractInfo[];
}): TransactionRequest[] {
  const resolver = expectedResolverAddress({ info, v2 });
  return names.flatMap((x) => {
    if (!x.claim) return [];
    if (x.claim === "ReverseClaimer") {
      // the owner is already claimed and should be owned by DAO
      return {
        to: v1.ENSRegistry,
        data: encodeFunctionData({
          abi: Abi_ENSRegistry,
          functionName: "setResolver",
          args: [namehash(getReverseName(x.address)), resolver],
        }),
      };
    }
    return {
      to: v2.ReverseRegistrarAdapter,
      data: encodeFunctionData({
        abi: Abi_ReverseRegistrarAdapter,
        functionName: "claim",
        args: [x.address, resolver],
      }),
    };
  });
}

export function createResolverCalls(names: DeployedContractInfo[]) {
  return names.flatMap((x) => {
    return [
      encodeFunctionData({
        abi: Abi_PermissionedResolver,
        functionName: "setName",
        args: [dnsEncodeName(getReverseName(x.address)), x.name],
      }),
      encodeFunctionData({
        abi: Abi_PermissionedResolver,
        functionName: "setAddress",
        args: [dnsEncodeName(x.name), COIN_TYPE_ETH, x.address],
      }),
    ];
  });
}

function resolveAccounts(chainId: number): NamingInfo {
  const label = "ens";
  switch (chainId) {
    case mainnet.id: {
      const DAO = "0xFe89cc7aBB2C4183683ab71653C4cdc9B02D44b7";
      const Cold = "0x690F0581eCecCf8389c223170778cD9D029606F2";
      const v1Owner = DAO;
      const v2Owner = DAO;
      return {
        chain: mainnet,
        publicRPC: "https://eth.drpc.org",
        label,
        v1Owner,
        isWrapped: false,
        v2Owner,
        wallets: {
          [DAO]: "DAO",
          [Cold]: "Cold",
          "0x0904Dac3347eA47d208F3Fd67402D039a3b99859": "Hot",
          "0x69420f05A11f617B4B74fFe2E04B2D300dFA556F": "swagalicious.eth",
        },
        managers: [Cold],
      };
    }
    case sepolia.id: {
      const DAO = "0x0F32b753aFc8ABad9Ca6fE589F707755f4df2353";
      const Greg = "0x179A862703a4adfb29896552DF9e307980D19285"; // current ens.eth owner
      return {
        chain: sepolia,
        publicRPC: "https://ethereum-sepolia-rpc.publicnode.com",
        label,
        v1Owner: Greg,
        isWrapped: true,
        v2Owner: DAO,
        wallets: {
          [DAO]: "DAO",
          [Greg]: "gregskril.eth",
          "0x4Fe4e666Be5752f1FdD210F4Ab5DE2Cc26e3E0e8": "Deployer",
        },
        managers: [],
      };
    }
    default:
      throw new Error(`unknown chain: ${chainId}`);
  }
}

export function filterContractInfos({
  v1,
  v2,
  names,
}: {
  v1: Deployments;
  v2: Deployments;
  names: ContractInfo[];
}): { found: DeployedContractInfo[]; missing: ContractInfo[] } {
  const found: DeployedContractInfo[] = [];
  const missing: ContractInfo[] = [];
  for (const x of names) {
    const address = v2[x.deployment] ?? v1[x.deployment];
    if (address) {
      found.push({ ...x, address });
    } else {
      missing.push(x);
    }
  }
  return { found, missing };
}

function dump(x: any) {
  console.log(JSON.stringify(x, null, "  "));
}

if (import.meta.main) {
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    options: {
      v2: {
        type: "string",
        default: "sepolia-20260915-r1", // "mainnet"
      },
      v1: { type: "string" },
      dao: { type: "boolean" },
    },
    strict: true,
    allowPositionals: true,
  });

  const baseDir = fileURLToPath(new URL("../", import.meta.url));
  const v2Dir = join(baseDir, `./deployments/${values.v2}/`);
  const v1Slug = values.v1 ?? values.v2.split("-")[0];
  const v1Dir = join(baseDir, `./lib/ens-contracts/deployments/${v1Slug}/`);

  const mode = positionals.shift()?.toLowerCase();
  const names = await getContractNames();
  const nameMax = names.reduce((a, x) => Math.max(a, x.name.length), 0);

  if (mode === "names") {
    console.table(
      names.map(({ name, deployment, claim }) => ({
        deployment,
        name: name.padStart(nameMax), // align right
        labels: name.split(".").length,
        claim,
      })),
    );
  } else if (mode === "owners") {
    const v1 = await readDeploymentAddresses(v1Dir, true);
    const info = resolveAccounts(await readDeploymentChainId(v1Dir));
    const client = createPublicClient({
      chain: info.chain,
      transport: http(info.publicRPC),
    });
    const owners = await Promise.all(
      Object.entries(v1).map(async ([name, address]) => {
        const owner = await readContract(client, {
          address: v1.ENSRegistry,
          abi: Abi_ENSRegistry,
          functionName: "owner",
          args: [namehash(getReverseName(address))],
        });
        return {
          name,
          named: names.find((x) => x.deployment === name) ? "Y" : "",
          owner: owner === zeroAddress ? "" : (info.wallets[owner] ?? owner),
          address,
        };
      }),
    );
    console.table(owners);
    const wrong = owners.filter((x) => x.owner && x.owner !== "DAO");
    if (wrong.length) {
      console.error("Incorrect Registry Owners:");
      console.table(wrong);
    }
  } else if (mode) {
    const v2 = await readDeploymentAddresses(v2Dir);
    const v1 = await readDeploymentAddresses(v1Dir, true);
    const chainId = await readDeploymentChainId(v2Dir);
    if (chainId !== (await readDeploymentChainId(v1Dir))) {
      throw new Error(`chain mismatch: ${v1.chainId} != ${v2.chainId}`);
    }
    const info = resolveAccounts(chainId);
    console.log(`Mode: ${mode}`);
    console.log(`Chain: ${chainId}`);
    console.log(`V1 Deployment: ${relative(baseDir, v1Dir)}`);
    console.log(`V2 Deployment: ${relative(baseDir, v2Dir)}`);
    function ownerStr(x: Address) {
      return `${x} ${info.wallets[x] ?? "?"}`;
    }
    console.log(
      `V1 Owner: ${ownerStr(info.v1Owner)} [wrapper=${info.isWrapped}]`,
    );
    console.log(`V2 Owner: ${ownerStr(info.v2Owner)}`);
    console.log(
      `Managers[${info.managers.length}]: ${info.managers.join(", ") || "<none>"}`,
    );
    console.log();

    const collisions = Object.keys(v1).filter((x) => v2[x]);
    if (collisions.length) {
      collisions.forEach((x, i) =>
        console.error(`[${i + 1}] Deployment Collision: ${x}`),
      );
      throw new Error("unexpected collisions");
    }

    function getDeployedNames() {
      const { found, missing } = filterContractInfos({ v1, v2, names });
      if (missing.length) {
        missing.forEach((x, i) =>
          console.error(`[${i + 1}] Cannot name: ${x.deployment}`),
        );
        console.error();
      }
      return found;
    }

    function createResolverTransactions(
      names: DeployedContractInfo[],
    ): TransactionRequest[] {
      const to = expectedResolverAddress({ info, v2 });
      return createResolverCalls(names).map((data) => ({
        to,
        data,
      }));
    }

    function dumpTransactions(trs: TransactionRequest[]) {
      dump(
        values.dao
          ? {
              to: trs.map((x) => x.to),
              values: trs.map(() => 0),
              calldatas: trs.map((x) => x.data),
            }
          : trs,
      );
    }

    switch (mode) {
      case "deployed": {
        console.table(
          getDeployedNames().map(({ deployment, address }) => ({
            deployment,
            address,
          })),
        );
        break;
      }
      case "deploy": {
        dumpTransactions([createDeployResolverTransaction({ info, v2 })]);
        break;
      }
      case "migrate": {
        dumpTransactions([createMigrationTransaction({ info, v1, v2 })]);
        break;
      }
      case "reverse": {
        dumpTransactions(
          createReverseRegistrarTransactions({
            info,
            v1,
            v2,
            names: getDeployedNames(),
          }),
        );
        break;
      }
      case "populate": {
        dumpTransactions(createResolverTransactions(getDeployedNames()));
        break;
      }
      case "init": {
        const names = getDeployedNames();
        dumpTransactions([
          createDeployResolverTransaction({ info, v2 }),
          createMigrationTransaction({ info, v1, v2 }),
          ...createReverseRegistrarTransactions({ info, v1, v2, names }),
          ...createResolverTransactions(names),
        ]);
        break;
      }
      default: {
        throw new Error("unknown mode");
      }
    }
  } else {
    console.table([
      {
        mode: "names",
        description: "Print contract deployments and names",
      },
      {
        mode: "owners",
        description: "Print reverse name owners",
      },
      {
        mode: "deployed",
        description: "Print named deployment addresses",
      },
      {
        mode: "deploy",
        description: "Transaction data for deploying PermissionedResolver",
      },
      {
        mode: "migrate",
        description: "Transaction data for ens.eth Migration",
      },
      {
        mode: "reverse",
        description: "Transaction data for populating PermissionedResolver",
      },
      {
        mode: "populate",
        description: "Transaction data for populating PermissionedResolver",
      },
      {
        mode: "init",
        description: "Generate calldata for initial deployment",
      },
    ]);
    console.table([
      {
        option: "--v2 {name}",
        description: "Deployment directory name for v2 contracts",
      },
      {
        option: "--v1 {name}",
        description: "Deployment directory name for v1 contracts",
      },
      {
        option: "--dao",
        description: "DAO-style calldata",
      },
    ]);
  }
}
