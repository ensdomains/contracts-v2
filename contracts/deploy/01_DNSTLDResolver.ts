import { execute } from "@rocketh";
import type { Abi_DNSSEC } from "generated/abis/DNSSEC.ts";
import type { Abi_ENSRegistry } from "generated/abis/ENSRegistry.ts";
import type { Abi_GatewayProvider } from "generated/abis/GatewayProvider.ts";
import type { Abi_OffchainDNSResolver } from "generated/abis/OffchainDNSResolver.ts";
import type { Abi_PermissionedRegistry } from "generated/abis/PermissionedRegistry.ts";
import type { Abi_SimplePublicSuffixList } from "generated/abis/SimplePublicSuffixList.ts";
import { Artifact_BatchRegistrar } from "generated/artifacts/BatchRegistrar.ts";
import { Artifact_DNSTLDResolver } from 'generated/artifacts/DNSTLDResolver.js';
import { labelhash, zeroAddress } from "viem";
import { MAX_EXPIRY, ROLES } from "../script/deploy-constants.js";
import { dnsEncodeName } from "../test/utils/utils.js";

async function fetchPublicSuffixes() {
  const res = await fetch(
    "https://publicsuffix.org/list/public_suffix_list.dat",
    { headers: { Connection: "close" } },
  );
  if (!res.ok) throw new Error(`expected suffixes: ${res.status}`);
  return (await res.text())
    .split("\n")
    .map((x) => x.trim())
    .filter((x) => x && !x.startsWith("//"));
}

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer },
    tags,
  }) => {
    const ensRegistryV1 =
      await getV1<Abi_ENSRegistry>("ENSRegistry");

    const dnsTLDResolverV1 = await getV1<Abi_OffchainDNSResolver>(
      "OffchainDNSResolver",
    );

    const publicSuffixList = await getV1<
      Abi_SimplePublicSuffixList
    >("SimplePublicSuffixList");

    const rootRegistry =
      get<Abi_PermissionedRegistry>("RootRegistry");

    const dnssecOracle = await getV1<Abi_DNSSEC>("DNSSECImpl");

    const batchGatewayProvider = await getV1<Abi_GatewayProvider>(
      "BatchGatewayProvider",
    );

    const dnssecGatewayProvider = get<
      Abi_GatewayProvider
    >("DNSSECGatewayProvider");

    const dnsTLDResolver = await deploy("DNSTLDResolver", {
      account: deployer,
      artifact: Artifact_DNSTLDResolver,
      args: [
        ensRegistryV1.address,
        dnsTLDResolverV1.address,
        rootRegistry.address,
        dnssecOracle.address,
        dnssecGatewayProvider.address,
        batchGatewayProvider.address,
      ],
    });

    let suffixes = tags.local
      ? ["com", "org", "net", "xyz"]
      : await fetchPublicSuffixes();
    suffixes = (
      await Promise.all(
        suffixes.map((suffix) =>
          read(publicSuffixList, {
            functionName: "isPublicSuffix",
            args: [dnsEncodeName(suffix)],
          }).then((pub) => (pub ? suffix : "")),
        ),
      ).then(async (suffixes) => {
        return await Promise.all(suffixes.map(async (suffix) => {
          return read(rootRegistry, {
            functionName: 'getStatus',
            args: [BigInt(labelhash(suffix))],
          }).then((status) => status === 0 ? suffix : "")
        }))
      })
    ).filter(Boolean);

    if (suffixes.length === 0) {
      console.warn("  - No suffixes found")
      return
    }

    const batchRegistrar = await deploy("RootBatchRegistrar", {
      account: deployer,
      artifact: Artifact_BatchRegistrar,
      args: [rootRegistry.address, deployer],
    });

    await write(rootRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        batchRegistrar.address,
      ],
    });

    // TODO: this create 1000+ transactions
    // batching is a mess in rocketh
    // anvil batching appears broken (only mines 1-2 tx)
    for (let i = 0; i < suffixes.length; i += 25) {
      const batch = suffixes.slice(i, i + 25)
      console.log(`  - Registering ${batch.length} suffixes (${Math.min(i + 25, suffixes.length)}/${suffixes.length})`)
      await write(batchRegistrar, {
        account: deployer,
        functionName: "batchRegister",
        args: [
          zeroAddress,
          dnsTLDResolver.address,
          batch,
          new Array(batch.length).fill(MAX_EXPIRY),
        ],
      })
    }

    // unauth batch registrar
    await write(rootRegistry, {
      account: deployer,
      functionName: 'revokeRootRoles',
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        batchRegistrar.address,
      ],
    })
  },
  {
    tags: ["DNSTLDResolver", "v2"],
    dependencies: [
      "RootRegistry",
      "OffchainDNSResolver", // "ENSRegistry" + "DNSSECImpl"
      "SimplePublicSuffixList",
      "BatchGatewayProvider",
      "DNSSECGatewayProvider",
    ],
  },
);
