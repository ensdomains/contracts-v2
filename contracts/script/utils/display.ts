import {
  decodeFunctionResult,
  encodeFunctionData,
  namehash,
  zeroAddress,
} from "viem";

import { artifacts } from "@rocketh";
import { MAX_EXPIRY } from "../deploy-constants.js";
import { dnsEncodeName } from "../../test/utils/utils.js";
import type { DevnetEnvironment } from "../setup.js";
import { traverseRegistry } from "./registry.js";

const PermissionedResolverAbi = artifacts.PermissionedResolver.abi;

/**
 * Display name information in a formatted table
 */
export async function showName(env: DevnetEnvironment, names: string[]) {
  await env.sync();

  const nameData = [];

  for (const name of names) {
    const nameHash = namehash(name);

    let owner: `0x${string}` | undefined = undefined;
    let expiryDate: string = "N/A";
    let registryAddress: `0x${string}` | undefined = undefined;

    const data = await traverseRegistry(env, name);
    if (data?.owner && data.owner !== zeroAddress) {
      owner = data.owner;
      registryAddress = data.registry;
      if (data.expiry) {
        const expiryTimestamp = Number(data.expiry);
        if (data.expiry === MAX_EXPIRY || expiryTimestamp === 0) {
          expiryDate = "Never";
        } else {
          expiryDate = new Date(expiryTimestamp * 1000).toISOString();
        }
      }
    }

    const actualResolver = data?.resolver;

    // Batch addr and text resolution using resolver multicall
    const resolverCalls = [
      encodeFunctionData({
        abi: PermissionedResolverAbi,
        functionName: "addr",
        args: [nameHash],
      }),
      encodeFunctionData({
        abi: PermissionedResolverAbi,
        functionName: "text",
        args: [nameHash, "description"],
      }),
    ];

    const multicallData = encodeFunctionData({
      abi: PermissionedResolverAbi,
      functionName: "multicall",
      args: [resolverCalls],
    });

    // Single UniversalResolver call with multicall
    let ethAddress: string | undefined;
    let description: string | undefined;

    try {
      const [result] =
        await env.deployment.contracts.UniversalResolverV2.read.resolve([
          dnsEncodeName(name),
          multicallData,
        ]);

      // Decode the multicall result - returns array of bytes directly
      const results =
        result && result !== "0x"
          ? (decodeFunctionResult({
              abi: PermissionedResolverAbi,
              functionName: "multicall",
              data: result,
            }) as readonly `0x${string}`[])
          : [];

      // Decode individual results
      ethAddress =
        results[0] && results[0] !== "0x"
          ? (decodeFunctionResult({
              abi: PermissionedResolverAbi,
              functionName: "addr",
              data: results[0],
            }) as string)
          : undefined;

      description =
        results[1] && results[1] !== "0x"
          ? (decodeFunctionResult({
              abi: PermissionedResolverAbi,
              functionName: "text",
              data: results[1],
            }) as string)
          : undefined;
    } catch {
      // Resolution may fail for names without a resolver (e.g., reserved or unregistered names)
    }

    const truncateAddress = (addr: string | undefined) => {
      if (!addr || addr === "0x") return "-";
      return addr.slice(0, 7);
    };

    nameData.push({
      Name: name,
      Registry: truncateAddress(registryAddress),
      Owner: truncateAddress(owner),
      Expiry: expiryDate === "Never" ? "Never" : expiryDate.split("T")[0],
      Resolver: truncateAddress(actualResolver),
      Address: truncateAddress(ethAddress),
      Description: description || "-",
    });
  }

  console.log(`\nName Information:`);
  console.table(nameData);
}
