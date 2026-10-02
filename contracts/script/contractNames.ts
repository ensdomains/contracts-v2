import { readFile, readdir } from "node:fs/promises";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { join, relative } from "node:path";
import {
  encodeFunctionData,
  TransactionRequest,
  zeroAddress,
  type Address,
} from "viem";
import { normalize } from "viem/ens";
import { Abi_VerifiableFactory } from "generated/abis/VerifiableFactory.js";
import { Abi_PermissionedResolver } from "generated/abis/PermissionedResolver.js";
import { Abi_NameWrapper } from "generated/abis/NameWrapper.js";
import { Abi_BaseRegistrarImplementation } from "generated/abis/BaseRegistrarImplementation.js";
import { Abi_ReverseRegistrarAdapter } from "generated/abis/ReverseRegistrarAdapter.js";
import { Abi_ENSRegistry } from "generated/abis/ENSRegistry.js";
import { config as RockethConfig } from "../rocketh/config.js";
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
  managers: Address[];
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

async function readChainId(dir: string): Promise<number> {
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

async function readDeployments(dir: string): Promise<Deployments> {
  const suffix = ".json";
  return Object.fromEntries(
    await Promise.all(
      (await readdir(dir))
        .filter((x) => x.endsWith(suffix) && !x.startsWith("."))
        .sort()
        .map(async (name) => {
          const json = JSON.parse(await readFile(join(dir, name), "utf8"));
          const slug = name.slice(0, -suffix.length);
          return [slug, json.address as Address];
        }),
    ),
  );
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

export function createClaimTransactions({
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
      // the owner is already claimed
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
    case 1: {
      const v1Owner = RockethConfig.accounts.owner.mainnet;
      const v2Owner = v1Owner;
      return {
        label,
        v1Owner,
        v2Owner,
        isWrapped: false,
        managers: [
          "0x690F0581eCecCf8389c223170778cD9D029606F2", // ens cold
          "0x0904Dac3347eA47d208F3Fd67402D039a3b99859", // ens hot
        ],
      };
    }
    case 11155111: {
      const v1Owner = "0x179A862703a4adfb29896552DF9e307980D19285"; // current ens.eth owner
      const v2Owner = RockethConfig.accounts.securityCouncil.sepolia;
      return { label, v1Owner, v2Owner, isWrapped: true, managers: [] };
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
        default: "sepolia", // "mainnet"
      },
      v1: {
        type: "string",
      },
    },
    strict: true,
    allowPositionals: true,
  });

  const mode = positionals.shift()?.toLowerCase();
  const names = await getContractNames();
  if (mode === "names") {
    const max = names.reduce((a, x) => Math.max(a, x.name.length), 0);
    console.table(
      names.map(({ name, deployment, claim }) => ({
        deployment,
        name: name.padStart(max), // align right
        claim,
      })),
    );
  } else if (mode) {
    const baseDir = fileURLToPath(new URL("../", import.meta.url));
    const v2Dir = join(baseDir, `./deployments/${values.v2}/`);
    const v2 = await readDeployments(v2Dir);
    if (!v2.RootRegistry) {
      throw new Error(`invalid V2 deployment: ${v2Dir}`);
    }
    const v1Slug = values.v1 ?? values.v2.split("-")[0];
    const v1Dir = join(baseDir, `./lib/ens-contracts/deployments/${v1Slug}/`);
    const v1 = await readDeployments(v1Dir);
    if (!v1.ENSRegistry) {
      throw new Error(`invalid V1 deployment: ${v1Dir}`);
    }
    const collisions = Object.keys(v1).filter((x) => v2[x]);
    const chainId = await readChainId(v2Dir);
    if (chainId !== (await readChainId(v2Dir))) {
      throw new Error(`chain mismatch: ${v1.chainId} != ${v2.chainId}`);
    }
    const info = resolveAccounts(chainId);
    console.log(`Mode: ${mode}`);
    console.log(`V1 Deployment: ${relative(baseDir, v1Dir)}`);
    console.log(`V2 Deployment: ${relative(baseDir, v2Dir)}`);
    if (collisions.length) {
      console.log(`Collisions[${collisions.length}]: ${collisions}`);
    }
    console.log(`V1 Owner: ${info.v2Owner} [wrapper=${info.isWrapped}]`);
    console.log(`V2 Owner: ${info.v2Owner}`);
    console.log(
      `Managers[${info.managers.length}]: ${info.managers.join(", ") || "<none>"}`,
    );
    console.log();

    function getDeployedNames() {
      const { found, missing } = filterContractInfos({ v1, v2, names });
      if (missing.length) {
        missing.forEach((x) => console.log(`Cannot name: ${x.deployment}`));
        console.log();
      }
      return found;
    }

    function createResolverTransactions(names: DeployedContractInfo[]) {
      const to = expectedResolverAddress({ info, v2 });
      return createResolverCalls(names).map((data) => ({
        to,
        data,
      }));
    }

    switch (mode) {
      case "deploy": {
        dump(createDeployResolverTransaction({ info, v2 }));
        break;
      }
      case "migrate": {
        dump(createMigrationTransaction({ info, v1, v2 }));
        break;
      }
      case "claim": {
        dump(
          createClaimTransactions({ info, v1, v2, names: getDeployedNames() }),
        );
        break;
      }
      case "populate": {
        dump(createResolverTransactions(getDeployedNames()));
        break;
      }
      case "init": {
        const names = getDeployedNames();
        dump([
          createDeployResolverTransaction({ info, v2 }),
          createMigrationTransaction({ info, v1, v2 }),
          createClaimTransactions({ info, v1, v2, names }),
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
        mode: "deploy",
        description: "Transaction data for deploying PermissionedResolver",
      },
      {
        mode: "migrate",
        description: "Transaction data for ens.eth Migration",
      },
      {
        mode: "populate",
        description: "Transaction data for populating PermissionedResolver",
      },
      {
        mode: "init",
        description: "Generate calldata for initial deployment",
      },
      // {
      //   mode: "diff",
      //   description: "Generate calldata for a change in deployment",
      // },
    ]);
  }
}
