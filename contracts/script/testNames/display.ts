import {
  decodeFunctionResult,
  encodeFunctionData,
  namehash,
  zeroAddress,
} from "viem";

import type { DevnetEnvironment } from "../setup.js";
import { MAX_EXPIRY, STATUS } from "../deploy-constants.js";
import { COIN_TYPE_ETH, dnsEncodeName } from "../../test/utils/utils.js";
import { getNameData } from "./registry.js";
import { MULTICALL_ABI, PROFILE_ABI } from "../../test/utils/resolvers.js";

/**
 * Display name information in a formatted table
 */
export async function showName(env: DevnetEnvironment, names: string[]) {
  await env.sync();

  const nameData = [];

  for (const name of names) {
    const node = namehash(name);

    const data = await getNameData(env, name);

    // Batch addr and text resolution using resolver multicall
    const resolverCalls = [
      encodeFunctionData({
        abi: PROFILE_ABI,
        functionName: "addr",
        args: [node, COIN_TYPE_ETH],
      }),
      encodeFunctionData({
        abi: PROFILE_ABI,
        functionName: "text",
        args: [node, "description"],
      }),
    ];

    const multicallData = encodeFunctionData({
      abi: MULTICALL_ABI,
      functionName: "multicall",
      args: [resolverCalls],
    });

    // Single UniversalResolver call with multicall
    let ethAddress: string | undefined;
    let description: string | undefined;

    try {
      const [result] = await env.v2.UniversalResolver.read.resolve([
        dnsEncodeName(name),
        multicallData,
      ]);

      // Decode the multicall result - returns array of bytes directly
      const results = decodeFunctionResult({
        abi: MULTICALL_ABI,
        functionName: "multicall",
        data: result,
      });

      // Decode individual results
      ethAddress = decodeFunctionResult({
        abi: PROFILE_ABI,
        functionName: "addr",
        data: results[0],
      });
      description = decodeFunctionResult({
        abi: PROFILE_ABI,
        functionName: "text",
        data: results[1],
      });
    } catch {
      // Resolution may fail for names without a resolver (e.g., reserved or unregistered names)
    }

    nameData.push({
      Name: name,
      Registry: truncateAddress(data?.parentRegistry.address),
      Status: formatStatus(data?.status),
      Owner: truncateAddress(data?.owner),
      Expiry: formatExpiry(data?.expiry ?? 0n),
      Resolver: truncateAddress(data?.resolver),
      Address: truncateAddress(ethAddress),
      Description: description || "-",
    });
  }

  console.log(`\nName Information:`);
  console.table(nameData);
}

/**
 * Display alias information for a list of candidate names.
 * For each name, queries its resolver's getAlias() to check for alias mappings.
 * Wildcard aliases (e.g., sub.alias.eth → sub.test.eth) are discovered automatically.
 *
 * NOTE: This uses Approach 1 (known candidates). For dynamic discovery via
 * AliasChanged events, see Approach 2 (planned for the indexer script).
 */
export async function showAlias(env: DevnetEnvironment, names: string[]) {
  // const aliasData = [];
  // for (const name of names) {
  //   const [resolverAddress] = await env.v2.UniversalResolver.read.findResolver([
  //     dnsEncodeName(name),
  //   ]);
  //   if (resolverAddress === zeroAddress) continue;
  //   const resolver = env.castPermissionedResolver(resolverAddress);
  //   try {
  //     const aliasResult = await resolver.read.getAlias([dnsEncodeName(name)]);
  //     if (aliasResult.length > 2) {
  //       const aliasTarget = dnsDecodeName(aliasResult);
  //       aliasData.push({
  //         Name: name,
  //         Resolver: truncateAddress(resolverAddress),
  //         "Alias Target": aliasTarget,
  //       });
  //     }
  //   } catch {
  //     // getAlias may fail if resolver doesn't support it
  //   }
  // }
  // if (aliasData.length > 0) {
  //   console.log(`\nAlias Information:`);
  //   console.table(aliasData);
  // } else {
  //   console.log(`\nNo aliases found.`);
  // }
}

export function truncateAddress(addr: string | undefined) {
  if (!addr || addr === "0x") return "-";
  return addr.slice(0, 7);
}

export function formatExpiry(sec: bigint) {
  switch (sec) {
    case 0n:
      return "Unset (0)";
    case MAX_EXPIRY:
      return "Never (MAX_EXPIRY)";
    default:
      return new Date(Number(sec) * 1000).toISOString();
  }
}

export function formatStatus(status: number | undefined) {
  for (const [k, x] of Object.entries(STATUS)) {
    if (x === status) {
      return k;
    }
  }
  return "UKNOWN";
}
