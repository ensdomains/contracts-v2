import { readFile, readdir } from "node:fs/promises";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { join, relative } from "node:path";
import {
  encodeAbiParameters,
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
import { config as RockethConfig } from "../rocketh/config.js";
import { computeOwnedResolverSalt } from "./salts.js";
import { ROLES } from "./deploy-constants.js";
import { computeVerifiableProxyAddress } from "../test/integration/fixtures/deployVerifiableProxy.js";
import { labelhash, namehash } from "../test/utils/utils.js";
import { migrationDataComponents } from "./migration.js";

// the profiles need stored in a resolver
// in v1, the records were in the PublicResolver
// in v2, we need a PermissionedResolver for "ens.eth"
// added: deploy/02_ENSPermissionedResolver.ts
// this requires custom rocketh stuff
// instead do it via calldata

// ens.eth should be migrated to v1
// but the new resolver will work in either v1 or v2

// all v1 contract primary names are already claimed by dao
// eg. root.ens.eth => 0xaB52... => owner(ab52...addr.reverse) = dao
// they need renamed to the legacy.ens.eth namespace
// need to figure out which contracts are forward only (eg. ENSRegistry, Root)
// and which are ReverseClaimer or Ownable (eg. Registrar, NameWrapper)

// all v2 contract primary names are claimable via owner (dao)
// so after new deployment, the first operation is for owner
// to claim every contract and update the name and resolver

const CLAIMS = [
  "Ownable",
  "DelegatedContractNamer",
  "IContractNamer",
  "Constructor",
] as const;

export type ContractNameInfo = {
  deployment: string;
  name: string;
  claim?: (typeof CLAIMS)[number];
};

export async function getContractNames(): Promise<ContractNameInfo[]> {
  return JSON.parse(
    await readFile(new URL("../docs/contractNames.json", import.meta.url), {
      encoding: "utf8",
    }),
  ).map((json: any) => {
    try {
      if (typeof json !== "object") {
        throw new Error("not object");
      } else if (typeof json.deployment !== "string") {
        throw new Error("invalid deployment");
      } else if (normalize(json.name) !== json.name) {
        throw new Error("invalid name");
      } else if (
        typeof json.claim !== "undefined" &&
        !CLAIMS.includes(json.claim)
      ) {
        throw new Error("invalid method");
      }
      return json;
    } catch (cause) {
      throw new Error(`invalid contract name: ${JSON.stringify(json)}`, {
        cause,
      });
    }
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

async function readDeployments(dir: string): Promise<Record<string, Address>> {
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

// function slugForChainId(chainId: number): string | undefined {
//   switch (chainId) {
//     case 1: return 'mainnet';
//     case 11155111: return 'sepolia';
//   }
// }

function resolveAccounts(chainId: number): {
  owner: Address;
  wrapped: boolean;
  managers: Address[];
} {
  switch (chainId) {
    case 1: {
      const owner = RockethConfig.accounts.owner.mainnet;
      const ensHot = "0x0904Dac3347eA47d208F3Fd67402D039a3b99859";
      const ensCold = "0x690F0581eCecCf8389c223170778cD9D029606F2";
      return { owner, wrapped: false, managers: [ensHot, ensCold] };
    }
    case 11155111: {
      const owner = RockethConfig.accounts.securityCouncil.sepolia;
      const greg = "0x179A862703a4adfb29896552DF9e307980D19285"; // current ens.eth owner
      return { owner, wrapped: true, managers: [greg] };
    }
    default:
      throw new Error(`unknown chain: ${chainId}`);
  }
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
      relative: {
        type: "boolean",
        short: "R",
      },
    },
    strict: true,
    allowPositionals: true,
  });

  const mode = positionals.shift()?.toLowerCase();
  if (mode === "names") {
    console.table(await getContractNames());
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
    const chainId = await readChainId(v2Dir);
    if (chainId !== (await readChainId(v2Dir))) {
      throw new Error(`chain mismatch: ${v1.chainId} != ${v2.chainId}`);
    }
    const { owner, wrapped, managers } = resolveAccounts(chainId);
    console.log(`Mode: ${mode}`);
    console.log(`V1 Deployment: ${relative(baseDir, v1Dir)}`);
    console.log(`V2 Deployment: ${relative(baseDir, v2Dir)}`);
    console.log(`Owner: ${owner}`);
    console.log(`Managers[${managers.length}]: ${managers.join(" ")}`);
    console.log();

    function deployResolverTx(): TransactionRequest {
      const initData = encodeFunctionData({
        abi: Abi_PermissionedResolver,
        functionName: "initialize",
        args: [
          [
            { account: owner, roleBitmap: ROLES.ALL },
            ...managers.map((account) => ({
              account,
              roleBitmap:
                ROLES.REGULAR &
                ~(ROLES.RESOLVER.SET_ADDRESS & ROLES.RESOLVER.UPGRADE),
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
            computeOwnedResolverSalt(owner),
            initData,
          ],
        }),
      };
    }

    function migrationTx(): TransactionRequest {
      const resolver = computeVerifiableProxyAddress({
        factoryAddress: v2.VerifiableFactory,
        proxyLogic: v2.PermissionedResolverImpl,
        deployer: owner,
        salt: computeOwnedResolverSalt(owner),
      });
      const label = "ens";
      const migrationData = encodeAbiParameters(migrationDataComponents, [
        label,
        owner,
        zeroAddress,
        resolver,
      ]);
      return wrapped
        ? {
            to: v1.NameWrapper,
            data: encodeFunctionData({
              abi: Abi_NameWrapper,
              functionName: "safeTransferFrom",
              args: [
                owner,
                v2.UnlockedMigrationController,
                BigInt(namehash(`${label}.eth`)),
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
                owner,
                v2.UnlockedMigrationController,
                BigInt(labelhash(label)),
                migrationData,
              ],
            }),
          };
    }

    function populateResolverTxs(): TransactionRequest[] {
      return [];
    }

    switch (mode) {
      case "deploy": {
        console.log(deployResolverTx());
        break;
      }
      case "migrate": {
        console.log(migrationTx());
        break;
      }
      case "populate": {
        console.log(populateResolverTxs());
        break;
      }
      case "init": {
        console.log([
          deployResolverTx(),
          migrationTx(),
          ...populateResolverTxs(),
        ]);
        break;
      }
      case "diff": {
        console.log("TODO");
        break;
      }
      default: {
        throw new Error("unknown mode");
      }
    }
  } else {
    console.table([
      { mode: "names", description: "Print contract deployments and names" },
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
      {
        mode: "diff",
        description: "Generate calldata for a change in deployment",
      },
    ]);
  }
}
